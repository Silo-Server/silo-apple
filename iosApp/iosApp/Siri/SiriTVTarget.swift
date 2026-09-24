#if os(iOS)
import Foundation

/// Picks the Apple TV for a Siri "play on TV" request without asking, when
/// the choice is obvious.
enum SiriTVTarget {
    /// The TV this phone controlled last, when it's on the network; else the
    /// only TV signed in to the phone's server. Nil when that leaves none or
    /// several, and the user picks.
    ///
    /// A TV on another server is never chosen silently: it may belong to
    /// someone else on the same network. TVs too old to play under the
    /// phone's profile are skipped, as the picker disables them.
    static func choose(
        from found: [SiloControlTarget],
        preferredId: String?,
        isOnActiveServer: (SiloControlTarget) -> Bool
    ) -> SiloControlTarget? {
        let playable = found.filter { $0.protocolVersion >= 2 }
        if let preferredId, let preferred = playable.first(where: { $0.id == preferredId }) {
            return preferred
        }
        let sameServer = playable.filter(isOnActiveServer)
        return sameServer.count == 1 ? sameServer.first : nil
    }

    /// Browses for Silo TVs for up to `timeout`, returning early once the
    /// preferred TV shows up.
    @MainActor
    static func discover(
        preferredId: String?,
        timeout: Duration = .seconds(3)
    ) async -> [SiloControlTarget] {
        let browser = SiloControlBrowser()
        browser.start()
        defer { browser.stop() }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let preferredId, browser.found.contains(where: { $0.id == preferredId }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return browser.found
    }
}
#endif
