#if os(iOS)
import SwiftUI

/// App-wide overlay: when a TV on the LAN is waiting for setup (`st=setup`)
/// or for sign-in (`st=login`), present the native-style pairing card
/// (`CompanionPairingCard`) rising from the bottom. Owns discovery
/// (`TVPairingBrowser`) and per-session "Not Now" dismissal.
///
/// A setup TV is offered when this device has any signed-in account to hand
/// off. A sign-in TV is offered only when this device holds a signed-in
/// account on a server whose verified identity is the TV's `srv`; that
/// server alone is pushed, for the one account the person picks. Both the
/// candidate and the latch read the same cached list of signed-in accounts
/// (`CompanionPairingOffer.make`), refreshed when auth or the accounts
/// change or the app returns to the foreground, so a TV this device can't
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
    /// Signed-in accounts on saved servers, the current one first
    /// (`CompanionPairingCoordinator.signedInAccounts`).
    @State private var signedIn: [CompanionPairingAccount] = []
    /// True once the active offer's TV no longer advertises that offer.
    @State private var offerWithdrawn = false
    @Environment(\.scenePhase) private var scenePhase

    /// When the signed-in accounts are re-read: auth changes, an account
    /// opened, a return to the foreground, and a TV starting to advertise.
    /// A newer key cancels the older read, so a slow read never overwrites a
    /// newer one.
    private struct SignedInRefreshKey: Equatable {
        let authState: AppRouter.AuthState
        let signInRevision: Int
        let isActive: Bool
        let hasAdverts: Bool
    }

    func body(content: Content) -> some View {
        content
            .task { browser.start() }
            .task(id: SignedInRefreshKey(
                authState: authState,
                signInRevision: SiloAccountCoordinator.shared.signInRevision,
                isActive: scenePhase == .active,
                hasAdverts: !browser.found.isEmpty
            )) {
                // The candidate may have been discovered while signed out;
                // a new token changes `candidate`, which latches it. With no
                // TV advertising there is nothing to offer, so skip the
                // keychain reads.
                guard scenePhase == .active, !browser.found.isEmpty else { return }
                await refreshSignedIn()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: browser.start()
                case .background: browser.stop()
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
                guard browser.isBrowsing else { return }
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
                    CompanionPairingCard(tv: tv, signInAccounts: offer.accounts, onDismiss: {
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
        return ([browser.isBrowsing ? "browsing" : "paused", offer] + adverts).joined(separator: ",")
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

    private func refreshSignedIn() async {
        let accounts = await CompanionPairingCoordinator.signedInAccounts()
        guard !Task.isCancelled else { return }
        if accounts != signedIn { signedIn = accounts }
    }
}

/// One TV the card is offering to help, and for a sign-in TV the accounts
/// it can be signed in with.
struct CompanionPairingOffer: Equatable {
    let tv: DiscoveredTV
    /// A sign-in TV's choices (`accounts(for:among:)`), the one to preselect
    /// first. Empty for a setup TV: the person chooses among every account
    /// once connected.
    let accounts: [CompanionPairingAccount]

    /// The sign-in TV's server, nil for a setup TV.
    var server: ServerEntry? { accounts.first?.server }

    /// What this device can offer `tv`: any signed-in account for a setup
    /// TV, the accounts on the TV's own server for a sign-in TV. Nil when
    /// there is nothing to offer. `signedIn` holds the signed-in accounts,
    /// the current one first.
    static func make(for tv: DiscoveredTV, signedIn: [CompanionPairingAccount]) -> CompanionPairingOffer? {
        switch tv.state {
        case .setup:
            return signedIn.isEmpty ? nil : CompanionPairingOffer(tv: tv, accounts: [])
        case .login:
            let choices = Self.accounts(for: tv, among: signedIn)
            return choices.isEmpty ? nil : CompanionPairingOffer(tv: tv, accounts: choices)
        }
    }

    /// The signed-in accounts on the server a sign-in TV asked for: the
    /// one whose verified identity is the TV's `srv`. Identity, not URL
    /// spelling, since one server has several addresses. The account this
    /// device uses there comes first: the current account when it is on
    /// that server, else the server's background account. Empty for a
    /// setup TV or a server this device has no account on.
    static func accounts(for tv: DiscoveredTV, among signedIn: [CompanionPairingAccount]) -> [CompanionPairingAccount] {
        guard tv.state == .login, let identity = ServerIdentity.usable(tv.serverIdentity) else { return [] }
        let onServer = signedIn.filter { $0.server.verifiedServerId == identity }
        let preferred = onServer.filter { $0.isCurrent || $0.isServerDefault }
        return preferred + onServer.filter { !$0.isCurrent && !$0.isServerDefault }
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
