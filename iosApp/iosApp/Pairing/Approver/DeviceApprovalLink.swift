import Foundation

/// `silo://device?server=<server_id>&url=<base>&code=<code>`: the web
/// approval page's "Open in the Silo app" link for a TV sign-in code.
///
/// A code means nothing without its server, so the link names the server by
/// its deployment identity (`GET /api/v2/system/identity`) and by an address
/// to add it from. When the link carries an identity, the app matches it
/// against its saved servers by identity, since one server has several
/// addresses; a link without one falls back to the exact address
/// (`DeviceLinkServerMatch`).
struct DeviceApprovalLink: Identifiable, Equatable, Sendable {
    /// The deployment identity, when the page knew it.
    let serverId: String?
    /// The server's address (normalized), for adding it when it isn't saved.
    let serverURL: String?
    /// Letters and digits only.
    let code: String

    var id: String { [serverId ?? "", serverURL ?? "", code].joined(separator: "|") }

    /// The link for `code` on a saved server, to reopen its approval later.
    init(server: ServerEntry, code: String) {
        self.serverId = ServerIdentity.usable(server.verifiedServerId)
        self.serverURL = ServerRegistry.normalize(url: server.url)
        self.code = DeviceUserCode.normalized(code)
    }

    /// `silo://device?server=&url=&code=` again, to re-handle once the app is
    /// ready for it (after adding the server, or signing in to it again).
    var url: URL? {
        var components = URLComponents()
        components.scheme = SiloURLScheme.current
        components.host = "device"
        components.queryItems = [
            serverId.map { URLQueryItem(name: "server", value: $0) },
            serverURL.map { URLQueryItem(name: "url", value: $0) },
            URLQueryItem(name: "code", value: code),
        ].compactMap { $0 }
        return components.url
    }

    init?(url: URL) {
        guard SiloURLScheme.isAppURL(url), url.host?.lowercased() == "device",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        let code = DeviceUserCode.normalized(value("code") ?? "")
        guard !code.isEmpty else { return nil }
        let serverURL = value("url").flatMap(Self.webOrigin)
        let serverId = ServerIdentity.usable(value("server"))
        guard serverId != nil || serverURL != nil else { return nil }
        self.code = code
        self.serverURL = serverURL
        self.serverId = serverId
    }

    /// Only an http(s) address with a host can be added or probed.
    private static func webOrigin(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return nil }
        return ServerRegistry.normalize(url: raw)
    }
}
