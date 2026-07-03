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
    private var generation = 0
    /// True between `start()` and `stop()` — gates self-heal restarts so a
    /// deliberate stop stays stopped.
    private var wantsBrowsing = false
    private nonisolated static let logger = Logger(subsystem: "com.continuum.app", category: "pairing.browser")

    func start() {
        guard browser == nil else { return }
        wantsBrowsing = true
        startBrowser()
    }

    private func startBrowser() {
        generation += 1
        let gen = generation
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PairingProtocol.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.found = results.compactMap(Self.makeTV)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                if case .failed(let error) = state {
                    Self.logger.error("browser failed: \(String(describing: error), privacy: .public)")
                    self.scheduleBrowserRestart()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func scheduleBrowserRestart() {
        browser?.cancel()
        browser = nil
        found = []
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.wantsBrowsing, self.browser == nil else { return }
            self.startBrowser()
        }
    }

    func stop() {
        wantsBrowsing = false
        generation += 1
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
