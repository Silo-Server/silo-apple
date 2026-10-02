#if os(iOS)
import SwiftUI

/// App-wide overlay: when a TV on the LAN is waiting for setup (`st=setup`)
/// or for sign-in (`st=login`), present the native-style pairing card
/// (`CompanionPairingCard`) rising from the bottom. Owns discovery
/// (`TVPairingBrowser`) and per-session "Not Now" dismissal.
///
/// A setup TV is offered when this device has any signed-in server to hand
/// off. A sign-in TV is offered only when this device holds a signed-in
/// server whose verified identity is the TV's `srv`; that server alone is
/// pushed. Both the candidate and the latch read the same cached list of
/// signed-in servers (`CompanionPairingOffer.make`), refreshed when auth
/// changes or the app returns to the foreground, so a TV this device can't
/// help never blocks one it can. Browsing pauses while the app is
/// backgrounded.
struct CompanionPairingCardModifier: ViewModifier {
    /// While false, discovery still runs but the card is withheld — used to
    /// keep the pairing offer from popping over the startup splash animation.
    var enabled: Bool = true
    /// Discovery can find a TV before this phone finishes signing in. Recheck
    /// eligibility whenever auth advances so that already-discovered TV is
    /// offered as soon as the new server token has been persisted.
    var authState: AppRouter.AuthState
    @State private var browser = TVPairingBrowser()
    @State private var dismissed: Set<String> = []
    @State private var active: CompanionPairingOffer?
    /// Saved servers holding a token, in preference order.
    @State private var signedIn: [ServerEntry] = []
    /// True once the active offer's TV no longer advertises that offer.
    @State private var offerWithdrawn = false
    /// False while the app is in the background: discovery is stopped and
    /// `browser.found` is empty, which says nothing about the TV.
    @State private var isBrowsing = true
    /// Numbers `refreshSignedIn` reads; only the newest one publishes.
    @State private var signedInGeneration = 0
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { browser.start() }
            .task(id: authState) {
                // The candidate may have been discovered while signed out;
                // a new token changes `candidate`, which latches it.
                await refreshSignedIn()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    browser.start()
                    isBrowsing = true
                    Task { await refreshSignedIn() }
                case .background:
                    browser.stop()
                    isBrowsing = false
                default: break
                }
            }
            .onChange(of: candidate) { _, newValue in
                // Latch onto a candidate when nothing is showing. We do NOT
                // auto-clear when it disappears: once setup begins the TV stops
                // advertising, and the card must persist to show progress/result.
                if let tv = newValue { latch(tv) }
            }
            .onChange(of: enabled) { _, isEnabled in
                // Splash just finished: offer any TV discovered in the meantime.
                if isEnabled, let tv = candidate { latch(tv) }
            }
            .task(id: offerSignature) {
                // A TV that changed state or session is withdrawn at once; one
                // that vanished gets a short grace period for Bonjour flaps.
                guard let offer = active else { offerWithdrawn = false; return }
                // Reassessed once discovery resumes in the foreground.
                guard isBrowsing else { return }
                switch Self.advertStatus(of: offer.tv, in: browser.found) {
                case .same:
                    offerWithdrawn = false
                case .changed:
                    offerWithdrawn = true
                case .gone:
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled { offerWithdrawn = true }
                }
            }
            .onChange(of: active) { old, new in
                offerWithdrawn = false
                // A card just closed (its TV is now in `dismissed`); offer the
                // next undismissed TV, if any.
                if old != nil, new == nil, let tv = candidate { latch(tv) }
            }
            .overlay {
                if let offer = active {
                    let tv = offer.tv
                    CompanionPairingCard(tv: tv, server: offer.server, onDismiss: {
                        // Every exit dismisses for the TV's current setup
                        // session (`sid`): predictable, and retry lives inside
                        // the card. A new session on the TV re-offers the card.
                        dismissed.insert(CompanionPairingDismissal.key(id: tv.id, sid: tv.sid))
                        active = nil
                    }, offerWithdrawn: offerWithdrawn)
                }
            }
    }

    /// Changes whenever the active offer or any advert's state or session
    /// changes. `DiscoveredTV` equality is id-only, so `found` alone won't do.
    private var offerSignature: String {
        let offer = active.map { "\($0.tv.id)|\($0.tv.state.rawValue)|\($0.tv.sid ?? "")" } ?? ""
        let adverts = browser.found.map { "\($0.id)|\($0.state.rawValue)|\($0.sid ?? "")" }
        return ([isBrowsing ? "browsing" : "paused", offer] + adverts).joined(separator: ",")
    }

    enum AdvertStatus: Equatable { case same, changed, gone }

    /// Whether `tv` (as offered) is still advertised unchanged.
    static func advertStatus(of tv: DiscoveredTV, in found: [DiscoveredTV]) -> AdvertStatus {
        guard let current = found.first(where: { $0.id == tv.id }) else { return .gone }
        return current.state == tv.state && current.sid == tv.sid ? .same : .changed
    }

    /// First discovered TV this device could help whose session hasn't been
    /// dismissed.
    private var candidate: DiscoveredTV? {
        browser.found.first { tv in
            guard !dismissed.contains(CompanionPairingDismissal.key(id: tv.id, sid: tv.sid)) else { return false }
            return CompanionPairingOffer.make(for: tv, signedIn: signedIn) != nil
        }
    }

    /// Show the card for `tv`, by the same rule that made it the candidate:
    /// a signed-out phone gets no dead-end prompt.
    private func latch(_ tv: DiscoveredTV) {
        guard enabled, active == nil, let offer = CompanionPairingOffer.make(for: tv, signedIn: signedIn) else { return }
        active = offer
    }

    /// Auth changes and returns to the foreground both refresh; a slower,
    /// older read never overwrites a newer one.
    private func refreshSignedIn() async {
        signedInGeneration += 1
        let generation = signedInGeneration
        let servers = await CompanionPairingCoordinator.serversWithTokens()
        guard generation == signedInGeneration else { return }
        if servers != signedIn { signedIn = servers }
    }
}

/// One TV the card is offering to help, and for a sign-in TV the one saved
/// server it asked for.
struct CompanionPairingOffer: Equatable {
    let tv: DiscoveredTV
    let server: ServerEntry?

    /// What this device can offer `tv`: any signed-in server for a setup
    /// TV (the user chooses), the TV's own server for a sign-in TV. Nil when
    /// there is nothing to offer. `signedIn` holds the saved servers with a
    /// token, in preference order.
    static func make(for tv: DiscoveredTV, signedIn: [ServerEntry]) -> CompanionPairingOffer? {
        switch tv.state {
        case .setup:
            return signedIn.isEmpty ? nil : CompanionPairingOffer(tv: tv, server: nil)
        case .login:
            return server(for: tv, among: signedIn).map { CompanionPairingOffer(tv: tv, server: $0) }
        }
    }

    /// The saved server a sign-in TV asked for: the one whose verified
    /// identity is the TV's `srv`. Identity, not URL spelling, since one
    /// server has several addresses. `servers` is in preference order
    /// (active first). Nil for a setup TV or a server this device lacks.
    static func server(for tv: DiscoveredTV, among servers: [ServerEntry]) -> ServerEntry? {
        guard tv.state == .login, let identity = ServerIdentity.usable(tv.serverIdentity) else { return nil }
        return servers.first { $0.verifiedServerId == identity }
    }
}

extension View {
    func companionPairingCard(
        enabled: Bool = true,
        authState: AppRouter.AuthState
    ) -> some View {
        modifier(CompanionPairingCardModifier(enabled: enabled, authState: authState))
    }
}
#endif
