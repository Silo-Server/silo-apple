#if os(iOS) || os(tvOS)
import Foundation
import Synchronization

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

final class DiagnosticsDestinationStore: Sendable {
    static let shared = DiagnosticsDestinationStore()

    private static let selectedDestinationKey = "diagnostics.destination.v1"
    private let defaults: SharedDefaults
    /// In-memory copy of the choice, because the log gate reads it on every
    /// line. Loaded on first read and written through by `select`; no other
    /// process writes the key.
    private let selection = Mutex<DiagnosticsDestinationChoice?>(nil)

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
    }

    var selectedDestination: DiagnosticsDestinationChoice {
        selection.withLock { selection in
            if let selection { return selection }
            let stored = defaults.string(forKey: Self.selectedDestinationKey)
                .flatMap(DiagnosticsDestinationChoice.init(rawValue:)) ?? .hosted
            selection = stored
            return stored
        }
    }

    func select(_ destination: DiagnosticsDestinationChoice) {
        // Outside the lock: a defaults write posts its change notification
        // synchronously, and an observer that logs would re-enter the getter.
        defaults.set(destination.rawValue, forKey: Self.selectedDestinationKey)
        selection.withLock { $0 = destination }
    }
}

extension DiagnosticsBinding {
    private static let hostedPrefix = "hosted:"
    private static let hostedAccountPrefix = "hosted-account:"

    var destinationChoice: DiagnosticsDestinationChoice {
        serverInstanceID.hasPrefix(Self.hostedPrefix) ? .hosted : .selfHosted
    }

    static func selfHosted(
        serverInstanceID: String,
        accountUserID: String
    ) -> DiagnosticsBinding? {
        guard !serverInstanceID.hasPrefix(Self.hostedPrefix) else { return nil }
        return DiagnosticsBinding(
            serverInstanceID: serverInstanceID,
            accountUserID: accountUserID
        )
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
