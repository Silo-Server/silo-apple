import Foundation
import Observation

// MARK: - Shared wire models

enum CardPosterSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }

    /// Artwork scale used by free-scrolling rails and standalone cards.
    /// Grids also adjust their column count so the selected size never causes
    /// overlapping focus frames.
    var scale: CGFloat {
        switch self {
        case .compact: return 0.86
        case .standard: return 1
        case .large: return 1.2
        }
    }
}

enum CardCaptionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case titleMetadata = "title_metadata"
    case title
    case artwork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleMetadata: return "Title & Metadata"
        case .title: return "Title Only"
        case .artwork: return "Artwork Only"
        }
    }

    var showsTitle: Bool { self != .artwork }
    var showsMetadata: Bool { self == .titleMetadata }
}

struct CardPresentationPreference: Codable, Equatable, Sendable {
    var posterSize: CardPosterSize
    var caption: CardCaptionStyle

    enum CodingKeys: String, CodingKey {
        case posterSize = "poster_size"
        case caption
    }

    static let standard = CardPresentationPreference(
        posterSize: .standard,
        caption: .titleMetadata
    )

    var preset: CardPresentationPreset? {
        CardPresentationPreset.allCases.first(where: { $0.presentation == self })
    }
}

/// Friendly cross-client recipes over the two contract axes. The server keeps
/// the normalized size/caption object, so a user can start from a preset and
/// still fine-tune either control without inventing another wire format.
enum CardPresentationPreset: String, CaseIterable, Identifiable, Sendable {
    case balanced
    case compact
    case cinema
    case artworkOnly = "artwork_only"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .compact: return "Compact"
        case .cinema: return "Cinema"
        case .artworkOnly: return "Artwork Only"
        }
    }

    var presentation: CardPresentationPreference {
        switch self {
        case .balanced:
            return .standard
        case .compact:
            return .init(posterSize: .compact, caption: .title)
        case .cinema:
            return .init(posterSize: .large, caption: .title)
        case .artworkOnly:
            return .init(posterSize: .large, caption: .artwork)
        }
    }
}

enum PrimaryMenuBuiltin: String, Codable, CaseIterable, Identifiable, Sendable {
    case home
    case movies
    case series
    case music
    case audiobooks
    case forYou = "for_you"
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .movies: return "Movies"
        case .series: return "Series"
        case .music: return "Music"
        case .audiobooks: return "Audiobooks"
        case .forYou: return "For You"
        case .calendar: return "Calendar"
        }
    }
}

/// One item in `nav.primary_menu` or `nav.shortcuts`.
///
/// The associated-value representation keeps impossible combinations out of
/// app state while custom coding preserves the contract's flat tagged object.
enum PrimaryMenuItem: Hashable, Identifiable, Sendable {
    case builtin(PrimaryMenuBuiltin)
    case library(libraryId: Int, label: String)
    case section(libraryId: Int, sectionId: String, label: String)
    case collection(collectionId: String, label: String, libraryId: Int?)

    var id: String {
        switch self {
        case .builtin(let destination):
            return "builtin:\(destination.rawValue)"
        case .library(let libraryId, _):
            return "library:\(libraryId)"
        case .section(let libraryId, let sectionId, _):
            return "section:\(libraryId):\(sectionId)"
        case .collection(let collectionId, _, let libraryId):
            let libraryValue = libraryId.map(String.init) ?? ""
            let libraryPresence = libraryId == nil ? "0" : "1"
            return "collection|\(libraryPresence)"
                + "|\(Self.identityComponent(libraryValue))"
                + "|\(Self.identityComponent(collectionId))"
        }
    }

    /// Pre-structured identity used by caches written before collection IDs
    /// became length-prefixed. It is accepted only while migrating an outbox;
    /// all live equality, deduplication, and focus identity uses ``id``.
    fileprivate var legacyUnstructuredId: String {
        switch self {
        case .collection(let collectionId, _, let libraryId):
            return "collection:\(libraryId.map(String.init) ?? "all"):\(collectionId)"
        default:
            return id
        }
    }

    var title: String {
        switch self {
        case .builtin(let destination): return destination.title
        case .library(_, let label), .section(_, _, let label), .collection(_, let label, _):
            return label
        }
    }

    var isHome: Bool { self == .builtin(.home) }

    var isContractValid: Bool {
        switch self {
        case .builtin:
            return true
        case .library(let libraryId, let label):
            return libraryId > 0 && Self.isValidLabel(label)
        case .section(let libraryId, let sectionId, let label):
            return libraryId > 0
                && Self.isValidTargetId(sectionId)
                && Self.isValidLabel(label)
        case .collection(let collectionId, let label, let libraryId):
            return (libraryId.map { $0 > 0 } ?? true)
                && Self.isValidTargetId(collectionId)
                && Self.isValidLabel(label)
        }
    }

    var libraryId: Int? {
        switch self {
        case .library(let id, _), .section(let id, _, _): return id
        case .collection(_, _, let id): return id
        case .builtin: return nil
        }
    }

    private static func isValidLabel(_ value: String) -> Bool {
        value.count <= 256
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isValidTargetId(_ value: String) -> Bool {
        value.count <= 128
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func identityComponent(_ value: String) -> String {
        "\(value.utf8.count)#\(value)"
    }
}

extension PrimaryMenuItem: Codable {
    private enum ItemType: String, Codable {
        case builtin
        case library
        case section
        case collection
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case destination
        case libraryId = "library_id"
        case sectionId = "section_id"
        case collectionId = "collection_id"
        case label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ItemType.self, forKey: .type) {
        case .builtin:
            self = .builtin(try container.decode(PrimaryMenuBuiltin.self, forKey: .destination))
        case .library:
            self = .library(
                libraryId: try container.decode(Int.self, forKey: .libraryId),
                label: try container.decode(String.self, forKey: .label)
            )
        case .section:
            self = .section(
                libraryId: try container.decode(Int.self, forKey: .libraryId),
                sectionId: try container.decode(String.self, forKey: .sectionId),
                label: try container.decode(String.self, forKey: .label)
            )
        case .collection:
            self = .collection(
                collectionId: try container.decode(String.self, forKey: .collectionId),
                label: try container.decode(String.self, forKey: .label),
                libraryId: try container.decodeIfPresent(Int.self, forKey: .libraryId)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let destination):
            try container.encode(ItemType.builtin, forKey: .type)
            try container.encode(destination, forKey: .destination)
        case .library(let libraryId, let label):
            try container.encode(ItemType.library, forKey: .type)
            try container.encode(libraryId, forKey: .libraryId)
            try container.encode(label, forKey: .label)
        case .section(let libraryId, let sectionId, let label):
            try container.encode(ItemType.section, forKey: .type)
            try container.encode(libraryId, forKey: .libraryId)
            try container.encode(sectionId, forKey: .sectionId)
            try container.encode(label, forKey: .label)
        case .collection(let collectionId, let label, let libraryId):
            try container.encode(ItemType.collection, forKey: .type)
            try container.encode(collectionId, forKey: .collectionId)
            try container.encode(label, forKey: .label)
            try container.encodeIfPresent(libraryId, forKey: .libraryId)
        }
    }
}

struct PrimaryMenuPreference: Codable, Equatable, Sendable {
    var items: [PrimaryMenuItem]

    /// The server validates this too. Rechecking at the client boundary makes
    /// a corrupt offline cache harmless instead of rendering a focus graph
    /// with no Home anchor or duplicate identities.
    var isValid: Bool {
        items.count >= 1
            && items.count <= 64
            && items.allSatisfy(\.isContractValid)
            && items.filter(\.isHome).count == 1
            && Set(items.map(\.id)).count == items.count
    }
}

struct NavigationShortcutsPreference: Codable, Equatable, Sendable {
    var items: [PrimaryMenuItem]

    static let empty = NavigationShortcutsPreference(items: [])
}

// MARK: - Transport

protocol UICustomizationTransport: AnyObject, Sendable {
    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult
    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse
    func putShortcutItem(
        _ item: PrimaryMenuItem,
        present: Bool,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws
    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws
    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws
}

extension UICustomizationTransport {
    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        .serverUpgradeRequired
    }

    func putShortcutItem(
        _ item: PrimaryMenuItem,
        present: Bool,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        throw URLError(.unsupportedURL)
    }

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        throw URLError(.unsupportedURL)
    }
}

final class ContinuumUICustomizationTransport: UICustomizationTransport {
    private let api: ContinuumAPI

    init(api: ContinuumAPI = .shared) {
        self.api = api
    }

    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        await api.getContractCapabilities(requestIdentity: requestIdentity)
    }

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        try await api.getEffectiveValues(
            keys: keys,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }

    func putShortcutItem(
        _ item: PrimaryMenuItem,
        present: Bool,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        _ = try await api.putNavigationShortcutItem(
            item,
            present: present,
            mutationId: mutationId,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        _ = try await api.putValue(
            key: key,
            scope: scope,
            value: value,
            mutationId: mutationId,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.deleteValue(
            key: key,
            scope: scope,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }
}

enum UICustomizationCapabilityState: Equatable, Sendable {
    case checking
    case supported
    case serverUpgradeRequired
    case unavailable

    var allowsEditing: Bool { self == .supported }

    var userMessage: String? {
        switch self {
        case .checking:
            return "Checking whether this server supports synced interface settings…"
        case .supported:
            return nil
        case .serverUpgradeRequired:
            return "Update this Silo server to use synced interface settings."
        case .unavailable:
            return "Interface settings are read-only until server support can be verified."
        }
    }
}

/// Last authoritative compatibility conclusion for one server/profile/family
/// cache. Probe failures are deliberately not conclusions: offline clients can
/// keep rendering a previously valid cache, while an explicitly older server
/// must not keep revision-5 navigation or card presentation active.
enum UICustomizationSupportProjection: String, Codable, Equatable, Sendable {
    case unknown
    case supported
    case knownUnsupported = "known_unsupported"

    var projectsCachedValues: Bool { self != .knownUnsupported }
}

// MARK: - Observable preference store

/// Effective UI customization for the active profile and client family.
///
/// Server values are authoritative when reachable. A per-profile/family cache
/// is painted first and updated optimistically so navigation and poster layout
/// remain useful offline; a failed sync never erases the last working UI.
@MainActor
@Observable
final class UICustomizationPreferences {
    static let shared = UICustomizationPreferences()

    private var storedPrimaryMenu: PrimaryMenuPreference?
    private var storedShortcuts: NavigationShortcutsPreference = .empty
    private var storedCardPresentation: CardPresentationPreference = .standard
    private var storedPrimaryMenuSource: SettingSource?
    private var storedCardPresentationSource: SettingSource?
    private(set) var isRefreshing = false
    private(set) var isSaving = false
    private(set) var syncErrorMessage: String?
    private(set) var capabilityState: UICustomizationCapabilityState = .checking
    private(set) var supportProjection: UICustomizationSupportProjection = .unknown

    var primaryMenu: PrimaryMenuPreference? {
        supportProjection.projectsCachedValues ? storedPrimaryMenu : nil
    }
    var shortcuts: NavigationShortcutsPreference {
        supportProjection.projectsCachedValues ? storedShortcuts : .empty
    }
    var cardPresentation: CardPresentationPreference {
        supportProjection.projectsCachedValues ? storedCardPresentation : .standard
    }
    var primaryMenuSource: SettingSource? {
        supportProjection.projectsCachedValues ? storedPrimaryMenuSource : nil
    }
    var cardPresentationSource: SettingSource? {
        supportProjection.projectsCachedValues ? storedCardPresentationSource : nil
    }

    var allowsEditing: Bool { capabilityState.allowsEditing }
    var capabilityMessage: String? { capabilityState.userMessage }

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let transport: UICustomizationTransport
    @ObservationIgnored private let cacheKey: @MainActor () -> String?
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var refreshSequence = 0
    @ObservationIgnored private var localMutationRevision = 0
    @ObservationIgnored private var saveTail: Task<Void, Never>?
    @ObservationIgnored private var pendingSaveCount = 0
    @ObservationIgnored private var syncErrorsByKey: [String: String] = [:]
    @ObservationIgnored private var shortcutSyncErrorsByIdentity: [String: String] = [:]
    @ObservationIgnored private var refreshSyncErrorMessage: String?
    @ObservationIgnored private var loadedCacheKey: String?
    @ObservationIgnored private var pendingSyncWrites: [String: PendingSyncWrite] = [:]
    @ObservationIgnored private var pendingShortcutOperations: [String: PendingShortcutOperation] = [:]
    @ObservationIgnored private var pendingShortcutPlacementBlockedIds: Set<String> = []
    @ObservationIgnored private var pendingDeletes: [String: PendingDelete] = [:]
    @ObservationIgnored private var nextShortcutOperationSequence: UInt64 = 0

    private struct OperationContext {
        let cacheKey: String
        let requestIdentity: HTTPRequestIdentity
    }

    private struct PendingSyncWrite: Codable {
        let value: SettingJSONValue
        /// The settings API requires one stable idempotency key for the whole
        /// lifetime of a retry. A new user edit replaces this record and gets
        /// a new mutation id; connectivity retries reuse the existing one.
        let mutationId: String
    }

    private struct PendingShortcutOperation: Codable {
        let item: PrimaryMenuItem
        let present: Bool
        /// True when this shortcut edit also authored this family's primary
        /// menu placement. The dependent menu write waits for shortcut
        /// acceptance so a rejected profile pin cannot commit only one half.
        let updatesPrimaryMenu: Bool
        /// Intended family-menu position for an accepted add. Keeping the
        /// authored index lets an earlier offline pin land ahead of later
        /// accepted pins when it is eventually replayed.
        let primaryMenuIndex: Int?
        /// Stable neighbor from the projected authored menu. The anchor keeps
        /// placement correct when an earlier pending removal still occupies an
        /// absolute slot at the time this add is accepted.
        let primaryMenuPredecessorId: String?
        /// Original catalog position used to restore a definitively rejected
        /// removal without replacing unrelated optimistic shortcut edits.
        let shortcutIndex: Int?
        /// Stable for every retry of this exact desired-presence operation.
        let mutationId: String
        /// Preserves user intent order across identities after a restart.
        let sequence: UInt64

        private enum CodingKeys: String, CodingKey {
            case item
            case present
            case updatesPrimaryMenu
            case primaryMenuIndex
            case primaryMenuPredecessorId
            case shortcutIndex
            case mutationId
            case sequence
        }

        init(
            item: PrimaryMenuItem,
            present: Bool,
            updatesPrimaryMenu: Bool,
            primaryMenuIndex: Int?,
            primaryMenuPredecessorId: String?,
            shortcutIndex: Int?,
            mutationId: String,
            sequence: UInt64
        ) {
            self.item = item
            self.present = present
            self.updatesPrimaryMenu = updatesPrimaryMenu
            self.primaryMenuIndex = primaryMenuIndex
            self.primaryMenuPredecessorId = primaryMenuPredecessorId
            self.shortcutIndex = shortcutIndex
            self.mutationId = mutationId
            self.sequence = sequence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedItem = try container.decode(PrimaryMenuItem.self, forKey: .item)
            item = decodedItem
            present = try container.decode(Bool.self, forKey: .present)
            updatesPrimaryMenu = try container.decodeIfPresent(
                Bool.self,
                forKey: .updatesPrimaryMenu
            ) ?? {
                if case .library = decodedItem { return true }
                return false
            }()
            primaryMenuIndex = try container.decodeIfPresent(Int.self, forKey: .primaryMenuIndex)
            primaryMenuPredecessorId = try container.decodeIfPresent(
                String.self,
                forKey: .primaryMenuPredecessorId
            )
            shortcutIndex = try container.decodeIfPresent(Int.self, forKey: .shortcutIndex)
            mutationId = try container.decode(String.self, forKey: .mutationId)
            sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        }

        func supersedingPrimaryMenuPlacement() -> Self {
            Self(
                item: item,
                present: present,
                updatesPrimaryMenu: false,
                primaryMenuIndex: primaryMenuIndex,
                primaryMenuPredecessorId: primaryMenuPredecessorId,
                shortcutIndex: shortcutIndex,
                mutationId: mutationId,
                sequence: sequence
            )
        }
    }

    private struct PendingDelete: Codable {
        let scope: SettingScope
        /// A local operation identity prevents an older queued DELETE from
        /// clearing a newer same-scope reset that still needs to be replayed.
        let operationId: String

        private enum CodingKeys: String, CodingKey {
            case scope
            case operationId
        }

        init(scope: SettingScope, operationId: String = newSettingMutationId()) {
            self.scope = scope
            self.operationId = operationId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = try container.decode(SettingScope.self, forKey: .scope)
            operationId = try container.decodeIfPresent(String.self, forKey: .operationId)
                ?? newSettingMutationId()
        }

        var scopeIdentity: SettingScopeIdentity? {
            switch scope {
            case .profileClient: return .profileClient
            case .profileDevice: return .profileDevice
            default: return nil
            }
        }
    }

    private struct Cache: Codable {
        let primaryMenu: PrimaryMenuPreference?
        let shortcuts: NavigationShortcutsPreference
        let cardPresentation: CardPresentationPreference
        let primaryMenuSource: SettingSource?
        let cardPresentationSource: SettingSource?
        let supportProjection: UICustomizationSupportProjection?
        let pendingSyncWrites: [String: PendingSyncWrite]?
        let pendingShortcutOperations: [String: PendingShortcutOperation]?
        let pendingShortcutPlacementBlockedIds: [String]?
        let pendingDeletes: [String: PendingDelete]?
    }

    init(
        defaults: SharedDefaults = .shared,
        transport: UICustomizationTransport = ContinuumUICustomizationTransport(),
        cacheKey: @escaping @MainActor () -> String? = UICustomizationPreferences.activeCacheKey,
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = UICustomizationPreferences.activeRequestIdentity,
        initialCapabilityState: UICustomizationCapabilityState = .checking
    ) {
        self.defaults = defaults
        self.transport = transport
        self.cacheKey = cacheKey
        self.requestIdentity = requestIdentity
        capabilityState = initialCapabilityState
        loadCache(for: cacheKey())
    }

    /// Repaint from the active identity's cache, then reconcile from the
    /// server. Transiently unknown servers retain the last compatible cache;
    /// explicitly older servers project the legacy/default presentation.
    func refresh() async {
        AppNavPreferences.shared.refresh()
        let targetCacheKey = cacheKey()
        loadCache(for: targetCacheKey)
        refreshSequence += 1
        let sequence = refreshSequence
        let mutationRevision = localMutationRevision
        isRefreshing = true
        defer {
            if refreshSequence == sequence {
                isRefreshing = false
            }
        }

        guard let identity = capturedIdentity(for: targetCacheKey) else {
            capabilityState = .unavailable
            refreshSyncErrorMessage = capabilityState.userMessage
            updateSyncErrorMessage()
            return
        }

        capabilityState = .checking
        // A new probe supersedes the prior probe/read failure. Per-key outbox
        // failures remain visible until their own retry succeeds.
        refreshSyncErrorMessage = nil
        updateSyncErrorMessage()
        let capabilities = await transport.contractCapabilities(requestIdentity: identity)
        guard refreshSequence == sequence,
              localMutationRevision == mutationRevision,
              cacheKey() == targetCacheKey,
              capturedIdentity(for: targetCacheKey) == identity else { return }

        switch capabilities {
        case .available(let capabilities) where capabilities.supportsUICustomizationRevision:
            capabilityState = .supported
            supportProjection = .supported
            saveCache(for: targetCacheKey)
        case .available, .serverUpgradeRequired:
            capabilityState = .serverUpgradeRequired
            supportProjection = .knownUnsupported
            refreshSyncErrorMessage = capabilityState.userMessage
            updateSyncErrorMessage()
            saveCache(for: targetCacheKey)
            return
        case .failed:
            capabilityState = .unavailable
            refreshSyncErrorMessage = capabilityState.userMessage
            updateSyncErrorMessage()
            return
        }

        do {
            guard await drainPendingWrites(
                targetCacheKey: targetCacheKey,
                requestIdentity: identity,
                sequence: sequence,
                mutationRevision: mutationRevision
            ) else { return }
            let response = try await transport.effectiveValues(
                keys: Self.keys,
                requestIdentity: identity
            )
            guard refreshSequence == sequence,
                  localMutationRevision == mutationRevision,
                  cacheKey() == targetCacheKey,
                  capturedIdentity(for: targetCacheKey) == identity else { return }
            let values = response.byKey

            if let row = values[.navPrimaryMenu] {
                storedPrimaryMenuSource = row.source
                if row.value.isNull {
                    storedPrimaryMenu = nil
                } else {
                    let decoded = try row.value.decoded(as: PrimaryMenuPreference.self)
                    storedPrimaryMenu = decoded.isValid ? decoded : nil
                }
            }
            if let row = values[.navShortcuts] {
                let decoded = try row.value.decoded(as: NavigationShortcutsPreference.self)
                storedShortcuts = Self.sanitizedShortcuts(decoded)
            }
            if let row = values[.uiCardPresentation] {
                storedCardPresentationSource = row.source
                storedCardPresentation = try row.value.decoded(as: CardPresentationPreference.self)
            }

            clearReconciledSyncErrors()
            saveCache(for: targetCacheKey)
        } catch {
            guard refreshSequence == sequence,
                  localMutationRevision == mutationRevision,
                  cacheKey() == targetCacheKey,
                  capturedIdentity(for: targetCacheKey) == identity else { return }
            refreshSyncErrorMessage = Self.message(for: error)
            updateSyncErrorMessage()
        }
    }

    func setCardPresentation(_ value: CardPresentationPreference) {
        guard !cardPresentationUsesDeviceOverride,
              let context = operationContext() else { return }
        localMutationRevision += 1
        storedCardPresentation = value
        storedCardPresentationSource = .scope(.profileClient)
        pendingDeletes.removeValue(
            forKey: Self.deleteIdentity(key: .uiCardPresentation, scope: .profileClient)
        )
        persist(
            key: .uiCardPresentation,
            scope: .profileClient,
            value: value,
            context: context
        )
    }

    func setPosterSize(_ value: CardPosterSize) {
        var updated = cardPresentation
        updated.posterSize = value
        setCardPresentation(updated)
    }

    func setCaptionStyle(_ value: CardCaptionStyle) {
        var updated = cardPresentation
        updated.caption = value
        setCardPresentation(updated)
    }

    func setPrimaryMenuItems(_ items: [PrimaryMenuItem]) {
        guard !primaryMenuUsesDeviceOverride,
              let context = operationContext() else { return }
        let acceptedIds = Set(resolvedPrimaryMenuItems().map(\.id))
        let unacceptedPinIds = Set(pendingShortcutOperations.values.compactMap { operation in
            operation.present ? operation.item.id : nil
        }).subtracting(acceptedIds)
        let blockedIds = Set(items.map(\.id)).intersection(unacceptedPinIds)
        guard blockedIds.isEmpty else {
            pendingShortcutPlacementBlockedIds = blockedIds
            setSyncError(Self.pendingShortcutPlacementMessage, for: .navPrimaryMenu)
            saveCache(for: context.cacheKey)
            return
        }
        let clearedPlacementBlock = !pendingShortcutPlacementBlockedIds.isEmpty
            || syncErrorsByKey[SettingKey.navPrimaryMenu.rawValue]
                == Self.pendingShortcutPlacementMessage
        pendingShortcutPlacementBlockedIds.removeAll()
        let didPersist = setPrimaryMenuItems(
            items,
            context: context,
            supersedesPendingShortcutPlacements: true
        )
        if clearedPlacementBlock && !didPersist {
            saveCache(for: context.cacheKey)
        }
    }

    @discardableResult
    private func setPrimaryMenuItems(
        _ items: [PrimaryMenuItem],
        context: OperationContext,
        advancesMutationRevision: Bool = true,
        supersedesPendingShortcutPlacements: Bool = false
    ) -> Bool {
        let normalized = Self.normalizedPrimaryMenuItems(items)
        guard normalized.count <= Self.maximumPrimaryMenuCount else {
            setSyncError(Self.primaryMenuLimitMessage, for: .navPrimaryMenu)
            return false
        }
        let value = PrimaryMenuPreference(items: normalized)
        guard value.isValid else { return false }
        if let menuError = syncErrorsByKey[SettingKey.navPrimaryMenu.rawValue],
           menuError == Self.primaryMenuLimitMessage
            || (menuError == Self.pendingShortcutPlacementMessage
                && pendingShortcutPlacementBlockedIds.isEmpty) {
            setSyncError(nil, for: .navPrimaryMenu)
        }
        if advancesMutationRevision {
            localMutationRevision += 1
        }
        if supersedesPendingShortcutPlacements {
            supersedePendingShortcutPlacements()
        }
        storedPrimaryMenu = value
        storedPrimaryMenuSource = .scope(.profileClient)
        pendingDeletes.removeValue(
            forKey: Self.deleteIdentity(key: .navPrimaryMenu, scope: .profileClient)
        )
        return persist(
            key: .navPrimaryMenu,
            scope: .profileClient,
            value: value,
            context: context
        )
    }

    func setLibraryPinned(_ library: Library, isPinned: Bool) {
        guard let context = operationContext() else { return }
        let item = PrimaryMenuItem.library(libraryId: library.id, label: library.name)
        guard item.isContractValid else { return }
        let currentShortcuts = shortcuts.items
        let alreadyPinned = currentShortcuts.contains { $0.id == item.id }
        guard alreadyPinned != isPinned else { return }
        guard !isPinned
                || currentShortcuts.count < Self.maximumShortcutCount else {
            setSyncError(Self.shortcutLimitMessage, for: .navShortcuts)
            return
        }

        var updatedMenu: [PrimaryMenuItem]?
        if !primaryMenuUsesDeviceOverride {
            var candidate = projectedPrimaryMenuItems().filter { $0.id != item.id }
            if isPinned { candidate.append(item) }
            let normalized = Self.normalizedPrimaryMenuItems(candidate)
            guard normalized.count <= Self.maximumPrimaryMenuCount else {
                setSyncError(Self.primaryMenuLimitMessage, for: .navPrimaryMenu)
                return
            }
            updatedMenu = normalized
        }

        setSyncError(nil, for: .navShortcuts)
        localMutationRevision += 1
        var updatedShortcuts = currentShortcuts.filter { $0.id != item.id }
        if isPinned { updatedShortcuts.append(item) }
        storedShortcuts = Self.sanitizedShortcuts(.init(items: updatedShortcuts))

        nextShortcutOperationSequence += 1
        let primaryMenuIndex = isPinned
            ? updatedMenu?.firstIndex(where: { $0.id == item.id })
            : nil
        let operation = PendingShortcutOperation(
            item: item,
            present: isPinned,
            updatesPrimaryMenu: updatedMenu != nil,
            primaryMenuIndex: primaryMenuIndex,
            primaryMenuPredecessorId: primaryMenuIndex.flatMap { index in
                guard index > 0 else { return nil }
                return updatedMenu?[index - 1].id
            },
            shortcutIndex: currentShortcuts.firstIndex(where: { $0.id == item.id }),
            mutationId: newSettingMutationId(),
            sequence: nextShortcutOperationSequence
        )
        pendingShortcutOperations[item.id] = operation
        reconcilePendingShortcutPlacementError()

        saveCache(for: context.cacheKey)
        enqueueShortcutOperation(
            operation,
            context: context
        )
    }

    func isLibraryPinned(_ libraryId: Int) -> Bool {
        shortcuts.items.contains {
            if case .library(let id, _) = $0 { return id == libraryId }
            return false
        }
    }

    /// The app-defined menu used when the contract value is null. Legacy
    /// audiobook opt-in remains part of that default until the user authors a
    /// new menu. Profile-wide shortcuts stay available to every family, but
    /// only an explicit family menu places them in that family's navigation.
    func resolvedPrimaryMenuItems(availableLibraries _: [Library] = []) -> [PrimaryMenuItem] {
        if let primaryMenu, primaryMenu.isValid {
            return primaryMenu.items
        }

        var items: [PrimaryMenuItem] = [
            .builtin(.home),
            .builtin(.movies),
            .builtin(.series),
            .builtin(.music),
        ]
        #if os(tvOS)
        // TVNavPreferences is the semantic owner used by the legacy tvOS
        // settings row (currently a typealias of AppNavPreferences).
        let legacyShowsAudiobooks = TVNavPreferences.shared.showAudiobooks
        #else
        let legacyShowsAudiobooks = AppNavPreferences.shared.showAudiobooks
        #endif
        if legacyShowsAudiobooks {
            items.append(.builtin(.audiobooks))
        }
        items.append(contentsOf: [.builtin(.forYou), .builtin(.calendar)])
        return Array(Self.deduplicated(items).prefix(Self.maximumPrimaryMenuCount))
    }

    var hasExplicitPrimaryMenu: Bool { primaryMenu != nil }
    var primaryMenuUsesDeviceOverride: Bool {
        primaryMenuSource == .scope(.profileDevice)
    }
    var cardPresentationUsesDeviceOverride: Bool {
        cardPresentationSource == .scope(.profileDevice)
    }
    var cardPresentationUsesFamilyOverride: Bool {
        cardPresentationSource == .scope(.profileClient)
    }
    var hasDeviceOverrides: Bool {
        primaryMenuUsesDeviceOverride || cardPresentationUsesDeviceOverride
    }

    /// Clear higher-precedence per-device rows so the family-scoped controls
    /// can truthfully represent and sync the effective value again.
    func useFamilySettings() {
        guard let context = operationContext() else { return }
        if primaryMenuUsesDeviceOverride {
            scheduleDelete(
                key: .navPrimaryMenu,
                scope: .profileDevice,
                context: context
            )
        }
        if cardPresentationUsesDeviceOverride {
            scheduleDelete(
                key: .uiCardPresentation,
                scope: .profileDevice,
                context: context
            )
        }
        let deletes = saveTail
        Task { @MainActor [weak self] in
            await deletes?.value
            guard let self,
                  self.contextIsCurrent(context),
                  self.syncErrorsByKey.isEmpty else { return }
            await self.refresh()
        }
    }

    /// Remove this family's explicit card row so resolution falls through to
    /// the profile-wide value or the contract default. This is distinct from
    /// clearing an older per-device row, which only exposes the family row.
    func resetCardPresentationToInherited() {
        guard let context = operationContext() else { return }
        localMutationRevision += 1
        pendingSyncWrites.removeValue(forKey: SettingKey.uiCardPresentation.rawValue)
        storedCardPresentationSource = nil
        scheduleDelete(
            key: .uiCardPresentation,
            scope: .profileClient,
            context: context
        )
        let delete = saveTail
        Task { @MainActor [weak self] in
            await delete?.value
            guard let self,
                  self.contextIsCurrent(context),
                  self.syncErrorsByKey[SettingKey.uiCardPresentation.rawValue] == nil else { return }
            await self.refresh()
        }
    }

    @discardableResult
    private func persist<T: Encodable>(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: T,
        context: OperationContext
    ) -> Bool {
        let encodedValue: SettingJSONValue
        do {
            encodedValue = try SettingJSONValue.encoding(value)
        } catch {
            setSyncError(Self.message(for: error), for: key)
            return false
        }
        let pendingWrite = PendingSyncWrite(
            value: encodedValue,
            mutationId: newSettingMutationId()
        )
        pendingSyncWrites[key.rawValue] = pendingWrite
        saveCache(for: context.cacheKey)
        enqueuePersist(
            key: key,
            scope: scope,
            write: pendingWrite,
            context: context
        )
        return true
    }

    private func enqueuePersist(
        key: SettingKey,
        scope: SettingScopeIdentity,
        write: PendingSyncWrite,
        context: OperationContext
    ) {
        let previousSave = saveTail
        pendingSaveCount += 1
        isSaving = true

        let save = Task { @MainActor [weak self] in
            await previousSave?.value
            guard let self else { return }
            defer { self.completeSave() }
            guard contextIsCurrent(context) else { return }
            do {
                try await transport.putValue(
                    key: key,
                    scope: scope,
                    value: write.value,
                    mutationId: write.mutationId,
                    requestIdentity: context.requestIdentity
                )
                guard contextIsCurrent(context) else { return }
                if pendingSyncWrites[key.rawValue]?.mutationId == write.mutationId {
                    pendingSyncWrites.removeValue(forKey: key.rawValue)
                    saveCache(for: context.cacheKey)
                }
                setSyncError(nil, for: key)
            } catch {
                guard contextIsCurrent(context) else { return }
                // Keep the optimistic cache. A later refresh or another edit
                // retries against the server without making the app unusable
                // while offline.
                setSyncError(Self.message(for: error), for: key)
            }
        }
        saveTail = save
    }

    private func enqueueShortcutOperation(
        _ operation: PendingShortcutOperation,
        context: OperationContext
    ) {
        let previousSave = saveTail
        pendingSaveCount += 1
        isSaving = true

        let save = Task { @MainActor [weak self] in
            await previousSave?.value
            guard let self else { return }
            defer { self.completeSave() }
            guard contextIsCurrent(context) else { return }
            do {
                try await transport.putShortcutItem(
                    operation.item,
                    present: operation.present,
                    mutationId: operation.mutationId,
                    requestIdentity: context.requestIdentity
                )
                guard contextIsCurrent(context) else { return }
                let identity = operation.item.id
                if let currentOperation = pendingShortcutOperations[identity],
                   currentOperation.mutationId == operation.mutationId {
                    pendingShortcutOperations.removeValue(forKey: identity)
                    shortcutSyncErrorsByIdentity.removeValue(forKey: identity)
                    reconcilePendingShortcutPlacementError()
                    let didPersistMenu = persistPrimaryMenuAfterShortcutAcceptance(
                        currentOperation,
                        context: context
                    )
                    if !didPersistMenu {
                        saveCache(for: context.cacheKey)
                    }
                    updateSyncErrorMessage()
                }
            } catch {
                guard contextIsCurrent(context) else { return }
                let identity = operation.item.id
                guard pendingShortcutOperations[identity]?.mutationId == operation.mutationId else {
                    return
                }
                shortcutSyncErrorsByIdentity[identity] = Self.shortcutMessage(for: error)
                if Self.isDefinitiveShortcutRejection(error) {
                    // The server proved this operation can never land as
                    // authored. Quarantine it from the durable outbox so a
                    // refresh can adopt the authoritative shortcut document
                    // instead of retrying forever from stale optimistic state.
                    pendingShortcutOperations.removeValue(forKey: identity)
                    rollbackRejectedShortcut(operation)
                    reconcilePendingShortcutPlacementError()
                    saveCache(for: context.cacheKey)
                    Task { @MainActor [weak self] in
                        guard let self, self.contextIsCurrent(context) else { return }
                        await self.refresh()
                    }
                }
                updateSyncErrorMessage()
            }
        }
        saveTail = save
    }

    private func rollbackRejectedShortcut(_ operation: PendingShortcutOperation) {
        var items = storedShortcuts.items.filter { $0.id != operation.item.id }
        if !operation.present {
            let index = min(max(operation.shortcutIndex ?? items.count, 0), items.count)
            items.insert(operation.item, at: index)
        }
        storedShortcuts = Self.sanitizedShortcuts(.init(items: items))
    }

    /// A rejected explicit menu edit records the exact optimistic pins it
    /// attempted to place. Unrelated pending pins must not keep that edit's
    /// validation error alive after its own blockers have settled.
    private func reconcilePendingShortcutPlacementError() {
        let acceptedIds = Set(resolvedPrimaryMenuItems().map(\.id))
        let unacceptedPinIds = Set(pendingShortcutOperations.values.compactMap { operation in
            operation.present && !acceptedIds.contains(operation.item.id)
                ? operation.item.id
                : nil
        })
        pendingShortcutPlacementBlockedIds.formIntersection(unacceptedPinIds)
        if pendingShortcutPlacementBlockedIds.isEmpty {
            guard syncErrorsByKey[SettingKey.navPrimaryMenu.rawValue]
                    == Self.pendingShortcutPlacementMessage else { return }
            setSyncError(nil, for: .navPrimaryMenu)
        } else {
            setSyncError(Self.pendingShortcutPlacementMessage, for: .navPrimaryMenu)
        }
    }

    @discardableResult
    private func persistPrimaryMenuAfterShortcutAcceptance(
        _ operation: PendingShortcutOperation,
        context: OperationContext
    ) -> Bool {
        guard operation.updatesPrimaryMenu,
              !primaryMenuUsesDeviceOverride else { return false }
        let previousItems = resolvedPrimaryMenuItems()
        var items = previousItems.filter { $0.id != operation.item.id }
        if operation.present {
            let index = primaryMenuInsertionIndex(for: operation, in: items)
            items.insert(operation.item, at: index)
        }
        let normalized = Self.normalizedPrimaryMenuItems(items)
        guard normalized != previousItems else { return false }
        let value = PrimaryMenuPreference(items: normalized)
        if let encoded = try? SettingJSONValue.encoding(value),
           pendingSyncWrites[SettingKey.navPrimaryMenu.rawValue]?.value == encoded {
            // A later explicit edit already queued this exact menu.
            return false
        }
        return setPrimaryMenuItems(
            normalized,
            context: context,
            advancesMutationRevision: false
        )
    }

    private func supersedePendingShortcutPlacements() {
        for (identity, operation) in pendingShortcutOperations
            where operation.updatesPrimaryMenu {
            pendingShortcutOperations[identity] = operation.supersedingPrimaryMenuPlacement()
        }
    }

    /// Project the final authored menu for validation without exposing an
    /// unaccepted shortcut as a live family-menu destination. Accepted
    /// callbacks apply these same ordered deltas to storedPrimaryMenu one at a
    /// time, so retries and definitive rejections cannot leak sibling intent.
    private func projectedPrimaryMenuItems() -> [PrimaryMenuItem] {
        var items = resolvedPrimaryMenuItems()
        let operations = pendingShortcutOperations.values.sorted {
            if $0.sequence == $1.sequence { return $0.item.id < $1.item.id }
            return $0.sequence < $1.sequence
        }
        for operation in operations where operation.updatesPrimaryMenu {
            items.removeAll { $0.id == operation.item.id }
            guard operation.present else { continue }
            let index = primaryMenuInsertionIndex(for: operation, in: items)
            items.insert(operation.item, at: index)
        }
        return Self.normalizedPrimaryMenuItems(items)
    }

    private func primaryMenuInsertionIndex(
        for operation: PendingShortcutOperation,
        in items: [PrimaryMenuItem]
    ) -> Int {
        if let predecessorId = operation.primaryMenuPredecessorId,
           let predecessorIndex = items.firstIndex(where: { $0.id == predecessorId }) {
            return predecessorIndex + 1
        }
        return min(max(operation.primaryMenuIndex ?? items.count, 0), items.count)
    }

    private func scheduleDelete(
        key: SettingKey,
        scope: SettingScopeIdentity,
        context: OperationContext
    ) {
        if scope.scope == .profileClient {
            pendingSyncWrites.removeValue(forKey: key.rawValue)
        }
        let pendingDelete = PendingDelete(scope: scope.scope)
        pendingDeletes[Self.deleteIdentity(key: key, scope: scope.scope)] = pendingDelete
        saveCache(for: context.cacheKey)
        enqueueDelete(
            key: key,
            scope: scope,
            pendingDelete: pendingDelete,
            context: context
        )
    }

    private func enqueueDelete(
        key: SettingKey,
        scope: SettingScopeIdentity,
        pendingDelete: PendingDelete,
        context: OperationContext
    ) {
        let previousSave = saveTail
        pendingSaveCount += 1
        isSaving = true

        let save = Task { @MainActor [weak self] in
            await previousSave?.value
            guard let self else { return }
            defer { self.completeSave() }
            guard contextIsCurrent(context) else { return }
            do {
                try await transport.deleteValue(
                    key: key,
                    scope: scope,
                    requestIdentity: context.requestIdentity
                )
                guard contextIsCurrent(context) else { return }
                let identity = Self.deleteIdentity(key: key, scope: scope.scope)
                if pendingDeletes[identity]?.operationId == pendingDelete.operationId {
                    pendingDeletes.removeValue(forKey: identity)
                }
                saveCache(for: context.cacheKey)
                setSyncError(nil, for: key)
            } catch {
                guard contextIsCurrent(context) else { return }
                if case .noValueAtScope = SettingsAPIError.from(error) {
                    let identity = Self.deleteIdentity(key: key, scope: scope.scope)
                    if pendingDeletes[identity]?.operationId == pendingDelete.operationId {
                        pendingDeletes.removeValue(forKey: identity)
                    }
                    saveCache(for: context.cacheKey)
                    setSyncError(nil, for: key)
                } else {
                    setSyncError("Could not reset this setting to its inherited value.", for: key)
                }
            }
        }
        saveTail = save
    }

    /// Durable optimistic writes are replayed before reading effective values.
    /// Otherwise an online refresh after an offline edit would replace the
    /// user's cached choice with the server's older value before retrying it.
    private func drainPendingWrites(
        targetCacheKey: String?,
        requestIdentity: HTTPRequestIdentity,
        sequence: Int,
        mutationRevision: Int
    ) async -> Bool {
        await saveTail?.value
        guard refreshSequence == sequence,
              localMutationRevision == mutationRevision,
              cacheKey() == targetCacheKey,
              capturedIdentity(for: targetCacheKey) == requestIdentity else { return false }

        guard let targetCacheKey else { return false }
        let context = OperationContext(
            cacheKey: targetCacheKey,
            requestIdentity: requestIdentity
        )
        let deletes = pendingDeletes.sorted(by: { $0.key < $1.key })
        let pendingShortcuts = pendingShortcutOperations.values.sorted {
            if $0.sequence == $1.sequence { return $0.item.id < $1.item.id }
            return $0.sequence < $1.sequence
        }
        let pending = Self.keys.compactMap { key -> (SettingKey, PendingSyncWrite)? in
            guard let write = pendingSyncWrites[key.rawValue],
                  Self.writeScope(for: key) != nil else { return nil }
            return (key, write)
        }
        guard !deletes.isEmpty || !pendingShortcuts.isEmpty || !pending.isEmpty else { return true }

        for (identity, delete) in deletes {
            guard let keyRaw = identity.split(separator: "|", maxSplits: 1).first,
                  let key = SettingKey(rawValue: String(keyRaw)),
                  let scope = delete.scopeIdentity else { continue }
            enqueueDelete(
                key: key,
                scope: scope,
                pendingDelete: delete,
                context: context
            )
        }
        for operation in pendingShortcuts {
            enqueueShortcutOperation(
                operation,
                context: context
            )
        }
        for (key, write) in pending {
            guard let scope = Self.writeScope(for: key) else { continue }
            enqueuePersist(
                key: key,
                scope: scope,
                write: write,
                context: context
            )
        }
        let replayTail = saveTail
        await replayTail?.value
        // An accepted shortcut may enqueue its dependent family-menu write.
        // Capture the new tail after the shortcut completes so refresh does
        // not return early with half of the compound pin still pending.
        await saveTail?.value
        guard refreshSequence == sequence,
              localMutationRevision == mutationRevision,
              cacheKey() == targetCacheKey,
              capturedIdentity(for: targetCacheKey) == requestIdentity else { return false }
        return pendingSyncWrites.isEmpty
            && pendingShortcutOperations.isEmpty
            && pendingDeletes.isEmpty
    }

    private func completeSave() {
        pendingSaveCount = max(0, pendingSaveCount - 1)
        isSaving = pendingSaveCount > 0
    }

    private func loadCache(for key: String?) {
        if loadedCacheKey != key {
            if loadedCacheKey != nil {
                capabilityState = .checking
            }
            loadedCacheKey = key
            clearSyncErrors()
        }
        storedPrimaryMenu = nil
        storedShortcuts = .empty
        storedCardPresentation = .standard
        storedPrimaryMenuSource = nil
        storedCardPresentationSource = nil
        supportProjection = .unknown
        pendingSyncWrites = [:]
        pendingShortcutOperations = [:]
        pendingShortcutPlacementBlockedIds = []
        pendingDeletes = [:]
        nextShortcutOperationSequence = 0
        guard let key,
              let data = defaults.data(forKey: key),
              let cached = try? SettingsWireCoding.makeDecoder().decode(Cache.self, from: data)
        else { return }
        storedPrimaryMenu = cached.primaryMenu?.isValid == true ? cached.primaryMenu : nil
        storedShortcuts = Self.sanitizedShortcuts(cached.shortcuts)
        storedCardPresentation = cached.cardPresentation
        storedPrimaryMenuSource = cached.primaryMenuSource
        storedCardPresentationSource = cached.cardPresentationSource
        supportProjection = cached.supportProjection ?? .unknown
        pendingSyncWrites = cached.pendingSyncWrites ?? [:]
        // Whole-document shortcut retries predate the atomic endpoint and
        // cannot be safely replayed without reintroducing lost updates.
        pendingSyncWrites.removeValue(forKey: SettingKey.navShortcuts.rawValue)
        pendingShortcutOperations = Self.validPendingShortcutOperations(
            cached.pendingShortcutOperations ?? [:]
        )
        pendingShortcutPlacementBlockedIds = Set(
            cached.pendingShortcutPlacementBlockedIds ?? []
        )
        pendingDeletes = Self.validPendingDeletes(cached.pendingDeletes ?? [:])
        nextShortcutOperationSequence = pendingShortcutOperations.values
            .map(\.sequence)
            .max() ?? 0
        reconcilePendingShortcutPlacementError()
    }

    private func saveCache(for key: String?) {
        guard let key,
              let data = try? SettingsWireCoding.makeEncoder().encode(Cache(
                primaryMenu: storedPrimaryMenu,
                shortcuts: storedShortcuts,
                cardPresentation: storedCardPresentation,
                primaryMenuSource: storedPrimaryMenuSource,
                cardPresentationSource: storedCardPresentationSource,
                supportProjection: supportProjection,
                pendingSyncWrites: pendingSyncWrites.isEmpty ? nil : pendingSyncWrites,
                pendingShortcutOperations: pendingShortcutOperations.isEmpty
                    ? nil
                    : pendingShortcutOperations,
                pendingShortcutPlacementBlockedIds: pendingShortcutPlacementBlockedIds.isEmpty
                    ? nil
                    : pendingShortcutPlacementBlockedIds.sorted(),
                pendingDeletes: pendingDeletes.isEmpty ? nil : pendingDeletes
              ))
        else { return }
        defaults.set(data, forKey: key)
    }

    /// Writes are serialized, but a later successful setting must not erase a
    /// failure from an earlier key (pinning a library writes shortcuts and the
    /// family menu back-to-back). A successful refresh is the only operation
    /// that proves the complete effective bundle reconciled.
    private func setSyncError(_ message: String?, for key: SettingKey) {
        if let message {
            syncErrorsByKey[key.rawValue] = message
        } else {
            syncErrorsByKey.removeValue(forKey: key.rawValue)
        }
        updateSyncErrorMessage()
    }

    private func clearSyncErrors() {
        syncErrorsByKey.removeAll()
        shortcutSyncErrorsByIdentity.removeAll()
        refreshSyncErrorMessage = nil
        updateSyncErrorMessage()
    }

    /// A successful effective read resolves ordinary write/read failures, but
    /// a definitive shortcut rejection remains useful after the optimistic
    /// state snaps back: it tells the user why their pin did not stick. The
    /// next successful operation for that semantic identity clears it.
    private func clearReconciledSyncErrors() {
        syncErrorsByKey.removeAll()
        refreshSyncErrorMessage = nil
        reconcilePendingShortcutPlacementError()
        updateSyncErrorMessage()
    }

    private func updateSyncErrorMessage() {
        let shortcutMessage = shortcutSyncErrorsByIdentity
            .sorted { $0.key < $1.key }
            .first?.value
        syncErrorMessage = refreshSyncErrorMessage
            ?? Self.keys.lazy.compactMap { key in
                self.syncErrorsByKey[key.rawValue]
                    ?? (key == .navShortcuts ? shortcutMessage : nil)
            }.first
    }

    private func operationContext() -> OperationContext? {
        guard allowsEditing,
              let targetCacheKey = cacheKey(),
              let identity = capturedIdentity(for: targetCacheKey) else { return nil }
        return OperationContext(cacheKey: targetCacheKey, requestIdentity: identity)
    }

    private func contextIsCurrent(_ context: OperationContext) -> Bool {
        cacheKey() == context.cacheKey
            && capturedIdentity(for: context.cacheKey) == context.requestIdentity
    }

    private func capturedIdentity(for targetCacheKey: String?) -> HTTPRequestIdentity? {
        guard let targetCacheKey,
              let identity = requestIdentity(),
              Self.cacheKey(for: identity) == targetCacheKey else { return nil }
        return identity
    }

    private static func activeCacheKey() -> String? {
        guard let identity = activeRequestIdentity() else { return nil }
        return cacheKey(for: identity)
    }

    private static func activeRequestIdentity() -> HTTPRequestIdentity? {
        guard let server = ServerRegistry.shared.activeServer,
              ServerRegistry.shared.activeServerId == server.id,
              let profileId = AuthService.shared.profileId,
              !profileId.isEmpty,
              server.profileId == profileId else { return nil }
        return HTTPRequestIdentity(
            serverId: server.id,
            serverURL: server.url,
            profileId: profileId,
            clientFamily: AppleDeviceIdentity.current.clientFamily
        )
    }

    private static func cacheKey(for identity: HTTPRequestIdentity) -> String {
        "silo.uiCustomization.\(identity.serverId).\(identity.profileId).\(identity.clientFamily)"
    }

    private static func deleteIdentity(key: SettingKey, scope: SettingScope) -> String {
        "\(key.rawValue)|\(scope.rawValue)"
    }

    private static let keys: [SettingKey] = [
        .navPrimaryMenu,
        .navShortcuts,
        .uiCardPresentation,
    ]

    private static let maximumPrimaryMenuCount = 64
    private static let maximumShortcutCount = 256
    private static let primaryMenuLimitMessage = "You can show up to 64 top-menu destinations."
    private static let shortcutLimitMessage = "You can pin up to 256 navigation shortcuts."
    private static let pendingShortcutPlacementMessage =
        "Wait for this library pin to finish syncing before placing it in the top menu."

    private static func writeScope(for key: SettingKey) -> SettingScopeIdentity? {
        switch key {
        case .navPrimaryMenu, .uiCardPresentation:
            return .profileClient
        default:
            return nil
        }
    }

    private static func validPendingShortcutOperations(
        _ operations: [String: PendingShortcutOperation]
    ) -> [String: PendingShortcutOperation] {
        var migrated: [String: PendingShortcutOperation] = [:]
        for (persistedIdentity, operation) in operations {
            let canonicalIdentity = operation.item.id
            guard (persistedIdentity == canonicalIdentity
                    || persistedIdentity == operation.item.legacyUnstructuredId),
                  operation.item.isContractValid,
                  !operation.mutationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            if case .builtin = operation.item { continue }

            if let existing = migrated[canonicalIdentity] {
                let existingWins = existing.sequence > operation.sequence
                    || (existing.sequence == operation.sequence
                        && existing.mutationId >= operation.mutationId)
                if existingWins { continue }
            }
            migrated[canonicalIdentity] = operation
        }
        return migrated
    }

    private static func validPendingDeletes(
        _ deletes: [String: PendingDelete]
    ) -> [String: PendingDelete] {
        deletes.filter { identity, delete in
            guard let keyRaw = identity.split(separator: "|", maxSplits: 1).first,
                  let key = SettingKey(rawValue: String(keyRaw)),
                  let scope = delete.scopeIdentity,
                  !delete.operationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            return identity == deleteIdentity(key: key, scope: scope.scope)
                && (key == .navPrimaryMenu || key == .uiCardPresentation)
        }
    }

    private static func sanitizedShortcuts(
        _ value: NavigationShortcutsPreference
    ) -> NavigationShortcutsPreference {
        let withoutBuiltins = value.items.filter {
            guard $0.isContractValid else { return false }
            if case .builtin = $0 { return false }
            return true
        }
        return .init(items: Array(deduplicated(withoutBuiltins).prefix(maximumShortcutCount)))
    }

    private static func deduplicated(_ items: [PrimaryMenuItem]) -> [PrimaryMenuItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func normalizedPrimaryMenuItems(
        _ items: [PrimaryMenuItem]
    ) -> [PrimaryMenuItem] {
        var normalized = deduplicated(items)
        if !normalized.contains(where: \.isHome) {
            normalized.insert(.builtin(.home), at: 0)
        }
        return normalized
    }

    private static func message(for error: Error) -> String {
        switch SettingsAPIError.from(error) {
        case .serverUpgradeRequired, .unknownSetting:
            return "Update this Silo server to sync interface preferences."
        case .transport:
            return "Saved on this device. Sync will resume when the server is reachable."
        default:
            return "Saved on this device, but the server did not accept the change."
        }
    }

    private static func shortcutMessage(for error: Error) -> String {
        switch SettingsAPIError.from(error) {
        case .invalidValue(let message) where message.contains("256"):
            return "This profile already has 256 navigation shortcuts. Unpin one and try again."
        case .invalidValue:
            return "The server rejected this shortcut. Check the selection and try again."
        case .mutationIdConflict:
            return "Another device changed this shortcut. The menu was refreshed; try again."
        default:
            return Self.message(for: error)
        }
    }

    private static func isDefinitiveShortcutRejection(_ error: Error) -> Bool {
        switch SettingsAPIError.from(error) {
        case .transport, .serverUpgradeRequired, .profileRequired,
             .unknownSetting, .server:
            return false
        case .clientLocalSetting, .scopeNotAllowed, .invalidValue,
             .mutationIdConflict, .noValueAtScope:
            return true
        }
    }
}
