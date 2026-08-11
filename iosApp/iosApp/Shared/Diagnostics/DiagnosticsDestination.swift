#if os(iOS) || os(tvOS)
import Foundation

enum DiagnosticsDestinationChoice: String, Codable, CaseIterable, Sendable {
    case hosted
    case selfHosted = "self_hosted"

    var title: String {
        switch self {
        case .hosted:
            return "Silo Diagnostics"
        case .selfHosted:
            return "My Silo Server"
        }
    }
}

final class DiagnosticsDestinationStore: @unchecked Sendable {
    static let shared = DiagnosticsDestinationStore()

    private static let selectedDestinationKey = "diagnostics.destination.v1"
    private let defaults: SharedDefaults
    private let lock = NSLock()

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
    }

    var selectedDestination: DiagnosticsDestinationChoice {
        lock.lock()
        defer { lock.unlock() }
        guard let rawValue = defaults.string(forKey: Self.selectedDestinationKey),
              let destination = DiagnosticsDestinationChoice(rawValue: rawValue) else {
            return .hosted
        }
        return destination
    }

    func select(_ destination: DiagnosticsDestinationChoice) {
        lock.lock()
        defaults.set(destination.rawValue, forKey: Self.selectedDestinationKey)
        lock.unlock()
    }

    func resetForTests() {
        lock.lock()
        defaults.removeObject(forKey: Self.selectedDestinationKey)
        lock.unlock()
    }
}

extension DiagnosticsBinding {
    private static let hostedPrefix = "hosted:"
    private static let hostedAccountPrefix = "hosted-account:"

    var destinationChoice: DiagnosticsDestinationChoice {
        serverInstanceID.hasPrefix(Self.hostedPrefix) ? .hosted : .selfHosted
    }

    static func hosted(serverRegistryID: String, accountUserID: String) -> DiagnosticsBinding {
        // This hash is local ownership state only. It scopes consent, pending
        // evidence, and retries to the Silo server/account that captured them.
        // Hosted manifests use the collector_id from /v1/capabilities instead
        // and never serialize this value or the reversible registry server ID.
        let sourceHash = DiagnosticsSHA256.shortHex(data: Data(serverRegistryID.utf8), count: 32)
        // Account identity is needed only to keep local consent and pending
        // evidence from crossing Silo accounts. Persist a domain-separated
        // opaque value in binding/consent sidecars rather than the server's raw
        // account identifier.
        let accountMaterial = "silo-hosted-account-v1|\(serverRegistryID)|\(accountUserID)"
        let accountHash = DiagnosticsSHA256.shortHex(data: Data(accountMaterial.utf8), count: 32)
        return DiagnosticsBinding(
            serverInstanceID: Self.hostedPrefix + sourceHash,
            accountUserID: Self.hostedAccountPrefix + accountHash
        )
    }
}
#endif
