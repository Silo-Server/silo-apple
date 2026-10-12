#if os(iOS)
import Foundation

enum ApplePushDeepLinkCoordinator {
    /// Query items naming the server and profile a push belongs to, so its
    /// link opens only under them (`opensUnderActiveIdentity`).
    static let serverIDQueryItem = "push_server_id"
    static let profileIDQueryItem = "push_profile_id"

    @MainActor
    static func postDeepLink(from userInfo: [AnyHashable: Any]) {
        guard let url = deepLinkURL(from: userInfo) else { return }
        SiloDeepLinkCoordinator.shared.receive(url)
    }

    /// A push that names its server and profile carries them in the link,
    /// which waits like any other until a profile is in use. A push that
    /// names only one of them has no link.
    static func deepLinkURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo[ApplePushDisplayWire.urlUserInfoKey] as? String,
              let url = deepLinkURL(fromDisplayURL: raw) else { return nil }
        guard ApplePushDisplayWire.namesTarget(userInfo) else { return url }
        guard let name = ApplePushDisplayWire.targetName(from: userInfo),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: serverIDQueryItem, value: name.serverID),
            URLQueryItem(name: profileIDQueryItem, value: name.profileID),
        ]
        return components.url
    }

    /// Whether `url` may open under the active server and profile. A link
    /// from a push that named its server and profile opens only under
    /// exactly those, so a tap never shows one server's or profile's item in
    /// another; the app opens without navigating instead. Other links open
    /// as before.
    static func opensUnderActiveIdentity(
        _ url: URL,
        activeServer: ServerEntry?,
        activeProfileID: String?,
        targets: ApplePushDisplayTargetStore = ApplePushDisplayTargetStore()
    ) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let serverID = items.first { $0.name == serverIDQueryItem }?.value
        let profileID = items.first { $0.name == profileIDQueryItem }?.value
        guard serverID != nil || profileID != nil else { return true }
        guard let serverID, let profileID, let activeServer, profileID == activeProfileID else { return false }
        if ServerIdentity.usable(activeServer.verifiedServerId) == serverID { return true }
        return targets.target(serverID: serverID, profileID: profileID)?.registryServerID == activeServer.id
    }

    static func deepLinkURL(fromDisplayURL rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), SiloURLScheme.isAppURL(url) {
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
        deepLink.scheme = SiloURLScheme.current
        deepLink.host = route
        deepLink.path = "/" + contentID
        return deepLink.url
    }
}
#endif
