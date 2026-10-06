import Foundation
import Observation

/// The server a sign-in screen is for: its name, address, and branding. The
/// sign-in itself lives in `LoginViewModel`; this only says who is asking.
/// Branding shows from the cache at once and refreshes from the server.
@MainActor
@Observable
final class SignInServerModel {
    private(set) var branding: ServerBranding?

    let serverURL: String
    private let loader: ServerBrandingLoader

    init(serverURL: String = AuthService.shared.serverUrl, loader: ServerBrandingLoader = ServerBrandingLoader()) {
        self.serverURL = serverURL
        self.loader = loader
        self.branding = ServerBrandingCache.branding(for: serverURL)
    }

    var serverName: String { ServerBranding.displayName(branding, serverURL: serverURL) }

    var hostLabel: String { ServerBranding.hostLabel(serverURL) }

    var isSecure: Bool { serverURL.lowercased().hasPrefix("https://") }

    /// Tints the backdrop for this server, then reads fresh branding.
    func load() async {
        MarqueeScene.shared.showServer(branding)
        // A screen already gone must not retint the next one.
        guard let fresh = await loader.branding(serverURL: serverURL), !Task.isCancelled else { return }
        branding = fresh
        MarqueeScene.shared.showServer(fresh)
    }
}
