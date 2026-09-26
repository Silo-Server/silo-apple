#if os(iOS)
import Foundation
import Network
import OSLog

/// A discovered Apple TV waiting to be set up.
struct DiscoveredTV: Identifiable, Equatable {
    let id: String          // TXT `id` (stable device id), or endpoint string.
    let name: String        // TXT `name`.
    let state: PairingReceiverState
    let endpoint: NWEndpoint
    let sid: String?        // TXT `sid`: per-advertising-session nonce, if present.
    // id-only equality is intentional: `sid`/`state` changes are surfaced via the
    // Optional nil↔value transition in CompanionPairingCardModifier's onChange latch,
    // not by field equality. Don't make this field-sensitive without revisiting that.
    static func == (a: DiscoveredTV, b: DiscoveredTV) -> Bool { a.id == b.id }
}

/// Browses `_silopair._tcp` and publishes discovered TVs. Drives the
/// hands-off card. Owns the Local Network permission prompt (triggered on
/// first browse).
///
/// Self-healing: this browser runs for as long as the app is foregrounded, so
/// a failed `NWBrowser` (post-suspension network-stack reset) restarts itself
/// instead of silently killing the feature until relaunch.
@MainActor
@Observable
final class TVPairingBrowser {
    private(set) var found: [DiscoveredTV] = []
    private var browser: NWBrowser?
    /// Active between `start()` and `stop()`, so a deliberate stop stays
    /// stopped.
    private let selfHeal: BonjourSelfHeal
    private nonisolated static let logger = Logger(subsystem: "org.siloserver.silo", category: "pairing.browser")

    init(selfHeal: BonjourSelfHeal = BonjourSelfHeal()) {
        self.selfHeal = selfHeal
    }

    func start() {
        guard browser == nil else { return }
        startBrowser()
    }

    private func startBrowser() {
        let gen = selfHeal.activate()
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PairingProtocol.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.selfHeal.isCurrent(gen) else { return }
                self.found = results.compactMap(Self.makeTV)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleStateUpdate(state, generation: gen)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func handleStateUpdate(_ state: NWBrowser.State, generation: Int) {
        guard selfHeal.isCurrent(generation), case .failed(let error) = state else { return }
        Self.logger.error("browser failed: \(String(describing: error), privacy: .public)")
        scheduleBrowserRestart()
    }

    private func scheduleBrowserRestart() {
        browser?.cancel()
        browser = nil
        found = []
        selfHeal.scheduleRestart { [weak self] in
            guard let self, self.browser == nil else { return }
            self.startBrowser()
        }
    }

    func stop() {
        selfHeal.deactivate()
        browser?.cancel()
        browser = nil
        found = []
    }

    private static func makeTV(_ result: NWBrowser.Result) -> DiscoveredTV? {
        guard case let .bonjour(txt) = result.metadata else { return nil }
        let name = txt["name"] ?? "Apple TV"
        let id = txt["id"] ?? "\(result.endpoint)"
        let state = PairingReceiverState(rawValue: txt["st"] ?? "setup") ?? .setup
        return DiscoveredTV(id: id, name: name, state: state, endpoint: result.endpoint, sid: txt["sid"])
    }
}
#endif
