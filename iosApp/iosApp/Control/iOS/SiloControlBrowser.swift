#if os(iOS)
import Foundation
import Network
import OSLog

struct SiloControlTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let serverId: String
    let serverName: String?
    let protocolVersion: Int
    /// The TV's advertised "currently playing" flag (Bonjour TXT `playing`).
    /// False for TVs running an older build that doesn't advertise it.
    var isPlaying: Bool = false
    /// The deployment identity behind the TV's server (Bonjour TXT
    /// `serverIdentity`). Nil for older TVs or servers.
    var serverIdentity: String? = nil

    static func == (lhs: SiloControlTarget, rhs: SiloControlTarget) -> Bool {
        lhs.id == rhs.id && lhs.isPlaying == rhs.isPlaying
            && lhs.serverId == rhs.serverId && lhs.protocolVersion == rhs.protocolVersion
            && lhs.serverIdentity == rhs.serverIdentity
    }

    /// Whether this TV is signed in to the phone's active server, by
    /// registry origin or by verified deployment identity.
    @MainActor
    var targetsActiveServer: Bool {
        let active = ServerRegistry.shared.activeServer
        return ServerRegistry.serversMatch(
            serverId: serverId, verifiedServerId: serverIdentity,
            serverId: active?.id, verifiedServerId: active?.verifiedServerId
        )
    }
}

/// Browses `_silocast._tcp` for TVs the phone can control.
///
/// Self-healing: a failed `NWBrowser` (for example after a post-suspension
/// network-stack reset) restarts itself until `stop()`, so the picker and the
/// auto-resume probe don't stay empty while TVs are advertising.
@MainActor
@Observable
final class SiloControlBrowser {
    private(set) var found: [SiloControlTarget] = []
    private var browser: NWBrowser?
    private let selfHeal: BonjourSelfHeal
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "control.browser"
    )

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
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: SiloControlProtocol.serviceType, domain: nil),
            using: params
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.selfHeal.isCurrent(gen) else { return }
                self.found = results
                    .compactMap { Self.makeTarget($0) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    /// Restarts discovery after the current browser fails. Only `.failed` is
    /// terminal; `NWBrowser` recovers from `.waiting` on its own.
    func handleStateUpdate(_ state: NWBrowser.State, generation: Int) {
        guard selfHeal.isCurrent(generation), case .failed(let error) = state else { return }
        Self.logger.error("browser failed: \(String(describing: error), privacy: .public)")
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

    private static func makeTarget(_ result: NWBrowser.Result) -> SiloControlTarget? {
        guard case let .bonjour(txt) = result.metadata else { return nil }
        guard let serverId = txt["server"], !serverId.isEmpty else { return nil }
        let deviceId = txt["id"] ?? "\(result.endpoint)"
        let name = txt["name"] ?? "Silo TV"
        return SiloControlTarget(
            id: deviceId,
            name: name,
            endpoint: result.endpoint,
            serverId: serverId,
            serverName: txt["serverName"],
            protocolVersion: Int(txt["v"] ?? "1") ?? 1,
            isPlaying: txt["playing"] == "1",
            serverIdentity: ServerIdentity.usable(txt["serverIdentity"])
        )
    }
}
#endif
