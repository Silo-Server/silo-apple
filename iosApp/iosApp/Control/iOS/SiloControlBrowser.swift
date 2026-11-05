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
    var transport: SiloControlTransport = .tls
    /// With `.sealed`, the ID of the Roku's current pairing key (TXT `kid`).
    var keyId: String? = nil

    static func == (lhs: SiloControlTarget, rhs: SiloControlTarget) -> Bool {
        lhs.id == rhs.id && lhs.isPlaying == rhs.isPlaying
            && lhs.serverId == rhs.serverId && lhs.protocolVersion == rhs.protocolVersion
            && lhs.serverIdentity == rhs.serverIdentity
            && lhs.transport == rhs.transport && lhs.keyId == rhs.keyId
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

/// Browses `_silocast._tcp` (Apple and Android TVs) and
/// `_silocast-roku._tcp` (Rokus) for TVs the phone can control, and lists
/// them together.
///
/// Self-healing: a failed `NWBrowser` (for example after a post-suspension
/// network-stack reset) restarts itself until `stop()`, so the picker and the
/// auto-resume probe don't stay empty while TVs are advertising.
@MainActor
@Observable
final class SiloControlBrowser {
    private(set) var found: [SiloControlTarget] = []
    private var browsers: [NWBrowser] = []
    private var foundByType: [String: [SiloControlTarget]] = [:]
    private nonisolated static let serviceTypes = [SiloControlProtocol.serviceType, SiloControlProtocol.rokuServiceType]
    private let selfHeal: BonjourSelfHeal
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "control.browser"
    )

    init(selfHeal: BonjourSelfHeal = BonjourSelfHeal()) {
        self.selfHeal = selfHeal
    }

    func start() {
        guard browsers.isEmpty else { return }
        startBrowsers()
    }

    private func startBrowsers() {
        let gen = selfHeal.activate()
        browsers = Self.serviceTypes.map { type in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    // A cancelled browser can still deliver results before
                    // the restart moves the generation on.
                    guard let self, self.selfHeal.isCurrent(gen), !self.browsers.isEmpty else { return }
                    self.foundByType[type] = results.compactMap { result in
                        guard case let .bonjour(txt) = result.metadata else { return nil }
                        return Self.makeTarget(txt: txt.dictionary, endpoint: result.endpoint, serviceType: type)
                    }
                    self.found = Self.merged(self.foundByType)
                }
            }
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleStateUpdate(state, generation: gen)
                }
            }
            browser.start(queue: .main)
            return browser
        }
    }

    /// Restarts discovery after a browser fails. Only `.failed` is terminal;
    /// `NWBrowser` recovers from `.waiting` on its own. Either type failing
    /// restarts both, so the two lists never fall out of step.
    func handleStateUpdate(_ state: NWBrowser.State, generation: Int) {
        guard selfHeal.isCurrent(generation), case .failed(let error) = state else { return }
        Self.logger.error("browser failed: \(String(describing: error), privacy: .public)")
        cancelBrowsers()
        selfHeal.scheduleRestart { [weak self] in
            guard let self, self.browsers.isEmpty else { return }
            self.startBrowsers()
        }
    }

    func stop() {
        selfHeal.deactivate()
        cancelBrowsers()
    }

    private func cancelBrowsers() {
        browsers.forEach { $0.cancel() }
        browsers = []
        foundByType = [:]
        found = []
    }

    /// Every type's TVs in one list by name, each device once.
    nonisolated static func merged(_ byType: [String: [SiloControlTarget]]) -> [SiloControlTarget] {
        var seen = Set<String>()
        return serviceTypes
            .flatMap { byType[$0] ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The target a TXT record describes. A Roku's transport comes from
    /// `sec`; one naming a level this build can't speak isn't listed.
    nonisolated static func makeTarget(txt: [String: String], endpoint: NWEndpoint, serviceType: String) -> SiloControlTarget? {
        guard let serverId = txt["server"], !serverId.isEmpty else { return nil }
        var transport = SiloControlTransport.tls
        var keyId: String?
        if serviceType == SiloControlProtocol.rokuServiceType {
            switch txt["sec"] ?? "plain" {
            case "plain":
                transport = .plain
            case "sealed":
                guard let kid = txt["kid"], !kid.isEmpty else { return nil }
                transport = .sealed
                keyId = kid.lowercased()
            default:
                return nil
            }
        }
        return SiloControlTarget(
            id: txt["id"] ?? "\(endpoint)",
            name: txt["name"] ?? (transport.isRoku ? "Roku" : "Silo TV"),
            endpoint: endpoint,
            serverId: serverId,
            serverName: txt["serverName"],
            protocolVersion: Int(txt["v"] ?? "1") ?? 1,
            isPlaying: txt["playing"] == "1",
            serverIdentity: ServerIdentity.usable(txt["serverIdentity"]),
            transport: transport,
            keyId: keyId
        )
    }
}
#endif
