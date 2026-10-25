#if os(iOS)
import Foundation
import Network
import OSLog

/// A discovered TV waiting to be set up (`st=setup`) or signed in
/// (`st=login`). Apple TVs and Android TVs advertise the same record; a
/// Roku advertises it under its own service type.
struct DiscoveredTV: Identifiable, Equatable {
    let id: String          // TXT `id` (stable device id), or endpoint string.
    let name: String        // TXT `name`.
    let state: PairingReceiverState
    let endpoint: NWEndpoint
    let sid: String?        // TXT `sid`: per-advertising-session nonce, if present.
    /// TXT `srv`: for a `login` TV, the deployment identity of the server
    /// it is signed out of.
    var serverIdentity: String? = nil
    /// Found as `_silopair-roku._tcp`: dialed over plain TCP, and signed in
    /// to one server only.
    var isRoku = false
    // id-only equality is intentional: `sid`/`state` changes are surfaced via the
    // Optional nil↔value transition in CompanionPairingCardModifier's onChange latch,
    // not by field equality. Don't make this field-sensitive without revisiting that.
    static func == (a: DiscoveredTV, b: DiscoveredTV) -> Bool { a.id == b.id }
}

/// Browses `_silopair._tcp` and `_silopair-roku._tcp` and publishes the
/// discovered TVs as one list. Drives the
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
    private var browsers: [NWBrowser] = []
    private var foundByType: [String: [DiscoveredTV]] = [:]
    private nonisolated static let serviceTypes = [PairingProtocol.serviceType, PairingProtocol.rokuServiceType]
    /// Active between `start()` and `stop()`, so a deliberate stop stays
    /// stopped.
    private let selfHeal: BonjourSelfHeal
    /// True between `start()` and `stop()`. While false, `found` is empty,
    /// which says nothing about any TV. Stored so views observe it.
    private(set) var isBrowsing = false
    private nonisolated static let logger = Logger(subsystem: "org.siloserver.silo", category: "pairing.browser")

    init(selfHeal: BonjourSelfHeal = BonjourSelfHeal()) {
        self.selfHeal = selfHeal
    }

    func start() {
        guard browsers.isEmpty else { return }
        isBrowsing = true
        startBrowsers()
    }

    private func startBrowsers() {
        let gen = selfHeal.activate()
        browsers = Self.serviceTypes.map { type in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: params)
            // Both handlers run on `.main` (see `start(queue:)` below).
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated {
                    // A cancelled browser can still deliver results before
                    // the restart moves the generation on.
                    guard let self, self.selfHeal.isCurrent(gen), !self.browsers.isEmpty else { return }
                    self.foundByType[type] = results.compactMap { Self.makeTV($0, serviceType: type) }
                    self.found = Self.merged(self.foundByType)
                }
            }
            browser.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    self?.handleStateUpdate(state, generation: gen)
                }
            }
            browser.start(queue: .main)
            return browser
        }
    }

    /// Every type's TVs in one list, each device once (the TLS record first).
    nonisolated static func merged(_ byType: [String: [DiscoveredTV]]) -> [DiscoveredTV] {
        var seen = Set<String>()
        return serviceTypes.flatMap { byType[$0] ?? [] }.filter { seen.insert($0.id).inserted }
    }

    func handleStateUpdate(_ state: NWBrowser.State, generation: Int) {
        guard selfHeal.isCurrent(generation), case .failed(let error) = state else { return }
        Self.logger.error("browser failed: \(String(describing: error), privacy: .public)")
        scheduleBrowserRestart()
    }

    /// Either type failing restarts both, so the lists never fall out of
    /// step.
    private func scheduleBrowserRestart() {
        cancelBrowsers()
        selfHeal.scheduleRestart { [weak self] in
            guard let self, self.browsers.isEmpty else { return }
            self.startBrowsers()
        }
    }

    func stop() {
        isBrowsing = false
        selfHeal.deactivate()
        cancelBrowsers()
    }

    private func cancelBrowsers() {
        browsers.forEach { $0.cancel() }
        browsers = []
        foundByType = [:]
        found = []
    }

    private static func makeTV(_ result: NWBrowser.Result, serviceType: String) -> DiscoveredTV? {
        guard case let .bonjour(txt) = result.metadata else { return nil }
        return makeTV(txt: txt.dictionary, endpoint: result.endpoint, serviceType: serviceType)
    }

    /// Reads one advertisement. A TV that names no state is a first-run TV
    /// (older TVs); an unknown state is not offered at all.
    nonisolated static func makeTV(
        txt: [String: String],
        endpoint: NWEndpoint,
        serviceType: String = PairingProtocol.serviceType
    ) -> DiscoveredTV? {
        typealias Key = PairingProtocol.TXTKey
        guard let state = PairingReceiverState(rawValue: txt[Key.state] ?? PairingReceiverState.setup.rawValue) else {
            return nil
        }
        let name = ServerIdentity.usable(txt[Key.name]) ?? "TV"
        let id = txt[Key.deviceId] ?? "\(endpoint)"
        return DiscoveredTV(id: id, name: name, state: state, endpoint: endpoint, sid: txt[Key.sessionNonce],
            serverIdentity: ServerIdentity.usable(txt[Key.serverIdentity]),
            isRoku: serviceType == PairingProtocol.rokuServiceType)
    }
}
#endif
