#if os(iOS)
import SwiftUI

/// App-wide overlay: when a blank Apple TV is discovered on the LAN, present the
/// native-style pairing card (`CompanionPairingCard`) rising from the bottom.
/// Owns discovery (`TVPairingBrowser`) and per-session "Not Now" dismissal.
///
/// The card is only offered when this device has a signed-in server to hand
/// off, and browsing pauses while the app is backgrounded.
struct CompanionPairingCardModifier: ViewModifier {
    @State private var browser = TVPairingBrowser()
    @State private var dismissed: Set<String> = []
    @State private var active: DiscoveredTV?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { browser.start() }
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
            .onChange(of: active) { old, new in
                // A card just closed (its TV is now in `dismissed`); offer the
                // next undismissed TV, if any.
                if old != nil, new == nil, let tv = candidate { latch(tv) }
            }
            .overlay {
                if let tv = active {
                    CompanionPairingCard(tv: tv) {
                        // Every exit dismisses for the TV's current setup
                        // session (`sid`): predictable, and retry lives inside
                        // the card. A new session on the TV re-offers the card.
                        dismissed.insert(CompanionPairingDismissal.key(id: tv.id, sid: tv.sid))
                        active = nil
                    }
                }
            }
    }

    /// First discovered TV awaiting setup whose session hasn't been dismissed.
    private var candidate: DiscoveredTV? {
        browser.found.first {
            $0.state == .setup
                && !dismissed.contains(CompanionPairingDismissal.key(id: $0.id, sid: $0.sid))
        }
    }

    /// Show the card for `tv` — but only if this device actually has a
    /// signed-in server to offer; a signed-out phone gets no dead-end prompt.
    private func latch(_ tv: DiscoveredTV) {
        guard active == nil else { return }
        Task { @MainActor in
            guard await CompanionPairingCoordinator.hasServerWithToken() else { return }
            guard active == nil else { return }
            active = tv
        }
    }
}

extension View {
    func companionPairingCard() -> some View { modifier(CompanionPairingCardModifier()) }
}
#endif
