import Foundation

// MARK: Settings contract capabilities

/// `GET /api/v2/settings/contract/capabilities`.
///
/// Two revisions travel here and they are not interchangeable: `revision` is
/// the opaque digest of this capability document (it changes whenever any
/// member does, so it is never compared as a number), while
/// `manifestRevision` is the settings manifest revision the server resolves
/// against, the number ``SettingKey/minimumServerRevision`` and each key's
/// ``SettingKey/introducedIn`` are compared with.
///
/// `supports_idempotent_writes` is deliberately not decoded: v2 advertises it
/// while offering no mutation-id replay, so nothing may gate on it.
struct APIv2SettingsContractCapabilities: Decodable, Hashable, Sendable {
    let revision: String
    /// `available`, `disabled`, `not_configured` or `unsupported`; kept as a
    /// string so a state added later reads back and is treated as unavailable.
    let state: String
    let allowed: Bool
    let manifestRevision: Int
    /// The client families a `profile_client` value may name.
    let clientFamilies: [String]
    let supportsBatchedEffective: Bool
    /// Revision-5 semantic shortcut mutations. Whole-document shortcut PUTs
    /// are intentionally not a safe fallback because concurrent clients can
    /// otherwise replace one another's pins.
    let supportsAtomicShortcuts: Bool

    /// The capability gate every v2 capability document shares.
    var isAvailable: Bool { allowed && state == "available" }

    /// True when the server's manifest is older than any this build
    /// supports. Newer servers, and older ones at or above the baseline, are
    /// usable; individual features gate on ``supports(_:)``.
    var predatesMinimumRevision: Bool {
        manifestRevision < SettingKey.minimumServerRevision
    }

    /// Whether the server's contract defines `key` and resolves it in batched
    /// reads — the same test the web client applies before offering a
    /// setting. Clients must hide definitions the server does not know rather
    /// than offer a choice it will refuse.
    func supports(_ key: SettingKey) -> Bool {
        isAvailable
            && key.isServed(atRevision: manifestRevision)
            && supportsBatchedEffective
    }

    /// Whether synced navigation and card presentation can run for
    /// `clientFamily`. Card presentation is stored at `profile_client`, so the
    /// server must accept this client's family for that scope.
    func supportsUICustomization(clientFamily: String) -> Bool {
        manifestRevision >= 5
            && supportsBatchedEffective
            && supportsAtomicShortcuts
            && clientFamilies.contains(clientFamily)
    }
}

// MARK: Overlay config

/// `GET /api/v2/settings/overlay-config`: the server-wide card overlay
/// baseline. `defaults` is a JSON-stringified `CardOverlayPrefs` document the
/// admin chose for profiles that have not customized, absent when none is set.
///
/// The quick-action members are required by the contract, so a reply without
/// them is not an overlay config. Nothing on Apple renders card quick actions
/// yet; they are decoded so the reply is checked against the whole contract.
struct APIv2OverlayConfig: Decodable, Hashable, Sendable {
    /// The admin kill switch for card overlays.
    let enabled: Bool
    let defaults: String?
    /// Default for profiles that have not chosen whether cards show quick
    /// actions.
    let quickActionsEnabled: Bool
    /// Default quick-action mode, one of the `ui.card_quick_actions` values.
    let quickActionsDefault: String
}
