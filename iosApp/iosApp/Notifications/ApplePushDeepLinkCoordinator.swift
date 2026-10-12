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
    /// names only one of them has no link. Only the push itself names them:
    /// the display URL comes from a server and cannot speak for another.
    static func deepLinkURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo[ApplePushDisplayWire.urlUserInfoKey] as? String,
              let url = deepLinkURL(fromDisplayURL: raw),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter {
            $0.name != serverIDQueryItem && $0.name != profileIDQueryItem
        }
        if ApplePushDisplayWire.namesTarget(userInfo) {
            guard let name = ApplePushDisplayWire.targetName(from: userInfo) else { return nil }
            items += [
                URLQueryItem(name: serverIDQueryItem, value: name.serverID),
                URLQueryItem(name: profileIDQueryItem, value: name.profileID),
            ]
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    enum Admission: Equatable {
        case open
        /// Hold the link until a profile is in use, then decide again.
        case wait
        /// Open the app without following the link.
        case drop
    }

    /// What the deep-link dispatcher does with `url` before any of its own
    /// branches: a link from a push that named its server and profile waits
    /// until a profile is in use, then opens only under exactly those,
    /// whatever kind of link it is (an item, a TV approval, a Watch Party
    /// invitation). Other links open as before.
    static func admission(
        for url: URL,
        profileInUse: Bool,
        activeServer: ServerEntry?,
        activeProfileID: String?,
        targets: ApplePushDisplayTargetStore = ApplePushDisplayTargetStore()
    ) -> Admission {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.contains(where: { $0.name == serverIDQueryItem || $0.name == profileIDQueryItem }) else {
            return .open
        }
        guard profileInUse else { return .wait }
        return opensUnderActiveIdentity(url, activeServer: activeServer, activeProfileID: activeProfileID,
                                        targets: targets) ? .open : .drop
    }

    /// Whether `url` may open under the active server and profile. A link
    /// from a push that named its server and profile opens only under
    /// exactly those, so a tap never shows one server's or profile's item in
    /// another; the app opens without navigating instead. When a saved
    /// server holds the target the push was displayed with, that saved
    /// server must be the active one; a server's reported identity counts
    /// only when no saved server holds one. Other links open as before.
    static func opensUnderActiveIdentity(
        _ url: URL,
        activeServer: ServerEntry?,
        activeProfileID: String?,
        targets: ApplePushDisplayTargetStore = ApplePushDisplayTargetStore()
    ) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let serverIDs = items.filter { $0.name == serverIDQueryItem }.map(\.value)
        let profileIDs = items.filter { $0.name == profileIDQueryItem }.map(\.value)
        guard !serverIDs.isEmpty || !profileIDs.isEmpty else { return true }
        // Exactly one of each, or the link's attribution cannot be trusted.
        guard serverIDs.count == 1, profileIDs.count == 1, let serverID = serverIDs[0], let profileID = profileIDs[0],
              let activeServer, profileID == activeProfileID else { return false }
        let claims = targets.targets(serverID: serverID, profileID: profileID)
        switch claims.count {
        case 0: return ServerIdentity.usable(activeServer.verifiedServerId) == serverID
        case 1: return claims[0].registryServerID == activeServer.id
        default: return false
        }
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
