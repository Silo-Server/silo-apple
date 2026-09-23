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

    var navigationIcon: String {
        switch self {
        case .home: return AppTab.home.icon
        case .movies: return "film.stack"
        case .series: return "tv"
        case .music: return "rectangle.stack"
        case .audiobooks: return "book.closed"
        case .forYou: return AppTab.recommendations.icon
        case .calendar: return AppTab.calendar.icon
        }
    }
}

func appleDefaultPrimaryMenuItems() -> [PrimaryMenuItem] {
    [
        .builtin(.home),
        .builtin(.movies),
        .builtin(.series),
        .builtin(.forYou),
        .builtin(.calendar),
    ]
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

    var navigationIcon: String {
        switch self {
        case .builtin(let destination): return destination.navigationIcon
        case .library, .section, .collection: return "rectangle.stack"
        }
    }

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
        requestIdentity: HTTPRequestIdentity
    ) async throws
    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
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

final class SiloUICustomizationTransport: UICustomizationTransport {
    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
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
            requestIdentity: requestIdentity
        )
    }

    func putShortcutItem(
        _ item: PrimaryMenuItem,
        present: Bool,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.putNavigationShortcutItem(item, present: present, requestIdentity: requestIdentity)
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.putValue(key: key, scope: scope, value: value, requestIdentity: requestIdentity)
    }

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.deleteValue(key: key, scope: scope, requestIdentity: requestIdentity)
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
    @ObservationIgnored private let writeRetryPolicy: SettingWriteRetryPolicy
    @ObservationIgnored private var outboxRetryTask: Task<Void, Never>?

    /// True while a change ran out of automatic retries and waits for
    /// "Try Again" or "Discard Held Change" (owner decision D4).
    private(set) var hasHeldChanges = false

    private struct OperationContext {
        let cacheKey: String
        let requestIdentity: HTTPRequestIdentity
    }

    /// Outbox bookkeeping shared by every pending write (owner decision D4).
    /// The operation id is local: it tells a late response apart from a newer
    /// edit of the same key and never leaves the device. Caches written by
    /// earlier builds stored it as `mutationId`.
    private struct OutboxRetryState: Codable, Equatable {
        /// Failed sends of this exact operation that a retry could fix.
        var failedAttempts = 0
        /// Out of automatic retries: kept and shown locally, not sent until
        /// the user retries or discards it.
        var isHeld = false
    }

    private struct PendingSyncWrite: Codable {
        let value: SettingJSONValue
        /// A new user edit replaces this record with a new id; a retry of the
        /// same value keeps it.
        let operationId: String
        var retry = OutboxRetryState()

        private enum CodingKeys: String, CodingKey {
            case value, operationId, retry
            case legacyMutationId = "mutationId"
        }

        init(value: SettingJSONValue, operationId: String = UUID().uuidString) {
            self.value = value
            self.operationId = operationId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(SettingJSONValue.self, forKey: .value)
            operationId = try container.decodeIfPresent(String.self, forKey: .operationId)
                ?? container.decodeIfPresent(String.self, forKey: .legacyMutationId)
                ?? UUID().uuidString
            retry = try container.decodeIfPresent(OutboxRetryState.self, forKey: .retry) ?? OutboxRetryState()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .value)
            try container.encode(operationId, forKey: .operationId)
            try container.encode(retry, forKey: .retry)
        }
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
        /// Local identity of this exact desired-presence operation, stable
        /// across its retries. Never sent.
        let operationId: String
        /// Preserves user intent order across identities after a restart.
        let sequence: UInt64
        var retry = OutboxRetryState()

        private enum CodingKeys: String, CodingKey {
            case item
            case present
            case updatesPrimaryMenu
            case primaryMenuIndex
            case primaryMenuPredecessorId
            case shortcutIndex
            case operationId
            case legacyMutationId = "mutationId"
            case sequence
            case retry
        }

        init(
            item: PrimaryMenuItem,
            present: Bool,
            updatesPrimaryMenu: Bool,
            primaryMenuIndex: Int?,
            primaryMenuPredecessorId: String?,
            shortcutIndex: Int?,
            operationId: String = UUID().uuidString,
            sequence: UInt64,
            retry: OutboxRetryState = OutboxRetryState()
        ) {
            self.item = item
            self.present = present
            self.updatesPrimaryMenu = updatesPrimaryMenu
            self.primaryMenuIndex = primaryMenuIndex
            self.primaryMenuPredecessorId = primaryMenuPredecessorId
            self.shortcutIndex = shortcutIndex
            self.operationId = operationId
            self.sequence = sequence
            self.retry = retry
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
            operationId = try container.decodeIfPresent(String.self, forKey: .operationId)
                ?? container.decode(String.self, forKey: .legacyMutationId)
            sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
            retry = try container.decodeIfPresent(OutboxRetryState.self, forKey: .retry) ?? OutboxRetryState()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(item, forKey: .item)
            try container.encode(present, forKey: .present)
            try container.encode(updatesPrimaryMenu, forKey: .updatesPrimaryMenu)
            try container.encodeIfPresent(primaryMenuIndex, forKey: .primaryMenuIndex)
            try container.encodeIfPresent(primaryMenuPredecessorId, forKey: .primaryMenuPredecessorId)
            try container.encodeIfPresent(shortcutIndex, forKey: .shortcutIndex)
            try container.encode(operationId, forKey: .operationId)
            try container.encode(sequence, forKey: .sequence)
            try container.encode(retry, forKey: .retry)
        }

        func supersedingPrimaryMenuPlacement() -> Self {
            Self(
                item: item,
                present: present,
                updatesPrimaryMenu: false,
                primaryMenuIndex: primaryMenuIndex,
                primaryMenuPredecessorId: primaryMenuPredecessorId,
                shortcutIndex: shortcutIndex,
                operationId: operationId,
                sequence: sequence,
                retry: retry
            )
        }
    }

    private struct PendingDelete: Codable {
        let scope: SettingScope
        /// A local operation identity prevents an older queued DELETE from
        /// clearing a newer same-scope reset that still needs to be replayed.
        let operationId: String
        var retry = OutboxRetryState()

        private enum CodingKeys: String, CodingKey {
            case scope
            case operationId
            case retry
        }

        init(scope: SettingScope, operationId: String = UUID().uuidString) {
            self.scope = scope
            self.operationId = operationId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = try container.decode(SettingScope.self, forKey: .scope)
            operationId = try container.decodeIfPresent(String.self, forKey: .operationId)
                ?? UUID().uuidString
            retry = try container.decodeIfPresent(OutboxRetryState.self, forKey: .retry) ?? OutboxRetryState()
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
        transport: UICustomizationTransport = SiloUICustomizationTransport(),
        cacheKey: @escaping @MainActor () -> String? = UICustomizationPreferences.activeCacheKey,
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = UICustomizationPreferences.activeRequestIdentity,
        initialCapabilityState: UICustomizationCapabilityState = .checking,
        writeRetryPolicy: SettingWriteRetryPolicy = .default
    ) {
        self.defaults = defaults
        self.transport = transport
        self.cacheKey = cacheKey
        self.requestIdentity = requestIdentity
        self.writeRetryPolicy = writeRetryPolicy
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
        case .available(let capabilities)
            where capabilities.supportsUICustomization(clientFamily: identity.clientFamily):
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
        case .unavailable, .failed:
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
            var decodedEveryValue = true
            let heldKeys = heldOutboxKeys
            for key in Self.keys where !heldKeys.contains(key) {
                guard let row = values[key] else {
                    setSyncError(Self.missingEffectiveValueMessage, for: key)
                    decodedEveryValue = false
                    continue
                }
                decodedEveryValue = applyEffectiveValue(row, for: key) && decodedEveryValue
            }

            if decodedEveryValue {
                clearReconciledSyncErrors()
            } else {
                refreshSyncErrorMessage = nil
                reconcilePendingShortcutPlacementError()
                updateSyncErrorMessage()
            }
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
        let pendingWrite = PendingSyncWrite(value: encodedValue)
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
                    requestIdentity: context.requestIdentity
                )
                guard contextIsCurrent(context) else { return }
                if pendingSyncWrites[key.rawValue]?.operationId == write.operationId {
                    pendingSyncWrites.removeValue(forKey: key.rawValue)
                    saveCache(for: context.cacheKey)
                }
                setSyncError(nil, for: key)
            } catch {
                guard contextIsCurrent(context) else { return }
                // Only the key's latest operation decides anything: an older
                // one was replaced by a newer edit, which reports for itself.
                guard var current = pendingSyncWrites[key.rawValue],
                      current.operationId == write.operationId else { return }
                switch SettingsAPIError.from(error, key: key.rawValue, scope: scope.scope).writeFailure {
                case .retry:
                    let held = recordRetryableFailure(&current.retry)
                    pendingSyncWrites[key.rawValue] = current
                    saveCache(for: context.cacheKey)
                    setSyncError(held ? HeldSettingChange.message : Self.message(for: error), for: key)
                    if !held { scheduleOutboxRetry(context: context) }
                case .release:
                    // A definite refusal: sending the same value again cannot
                    // land. Release it; the next refresh repaints the server's
                    // value.
                    pendingSyncWrites.removeValue(forKey: key.rawValue)
                    saveCache(for: context.cacheKey)
                    setSyncError(Self.message(for: error), for: key)
                case .ownerChanged, .waitForCondition:
                    // Keep the optimistic cache. A later refresh or another
                    // edit retries against the server without making the app
                    // unusable while offline.
                    setSyncError(Self.message(for: error), for: key)
                }
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
                    requestIdentity: context.requestIdentity
                )
                guard contextIsCurrent(context) else { return }
                let identity = operation.item.id
                if let currentOperation = pendingShortcutOperations[identity],
                   currentOperation.operationId == operation.operationId {
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
                guard var current = pendingShortcutOperations[identity],
                      current.operationId == operation.operationId else {
                    return
                }
                shortcutSyncErrorsByIdentity[identity] = Self.shortcutMessage(for: error)
                if SettingsAPIError.from(error).writeFailure == .retry {
                    let held = recordRetryableFailure(&current.retry)
                    pendingShortcutOperations[identity] = current
                    saveCache(for: context.cacheKey)
                    if held {
                        shortcutSyncErrorsByIdentity[identity] = HeldSettingChange.message
                    } else {
                        scheduleOutboxRetry(context: context)
                    }
                } else if Self.isDefinitiveShortcutRejection(error) {
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
                await finishAcceptedDelete(
                    key: key,
                    scope: scope,
                    pendingDelete: pendingDelete,
                    context: context
                )
            } catch {
                guard contextIsCurrent(context) else { return }
                let mapped = SettingsAPIError.from(error, key: key.rawValue, scope: scope.scope)
                if case .noValueAtScope = mapped {
                    await finishAcceptedDelete(
                        key: key,
                        scope: scope,
                        pendingDelete: pendingDelete,
                        context: context
                    )
                } else {
                    let identity = Self.deleteIdentity(key: key, scope: scope.scope)
                    guard var current = pendingDeletes[identity],
                          current.operationId == pendingDelete.operationId else {
                        return
                    }
                    var message = "Could not reset this setting to its inherited value."
                    switch mapped.writeFailure {
                    case .retry:
                        let held = recordRetryableFailure(&current.retry)
                        pendingDeletes[identity] = current
                        saveCache(for: context.cacheKey)
                        if held {
                            message = HeldSettingChange.message
                        } else {
                            scheduleOutboxRetry(context: context)
                        }
                    case .release:
                        pendingDeletes.removeValue(forKey: identity)
                        saveCache(for: context.cacheKey)
                    case .ownerChanged, .waitForCondition:
                        break
                    }
                    setSyncError(message, for: key)
                }
            }
        }
        saveTail = save
    }

    /// A successful device-row delete changes the effective value immediately,
    /// even if another queued delete fails. Reconcile only this accepted key so
    /// a failed sibling remains durable for retry without blocking the value
    /// that the server has already exposed underneath the deleted override.
    private func finishAcceptedDelete(
        key: SettingKey,
        scope: SettingScopeIdentity,
        pendingDelete: PendingDelete,
        context: OperationContext
    ) async {
        let identity = Self.deleteIdentity(key: key, scope: scope.scope)
        guard pendingDeletes[identity]?.operationId == pendingDelete.operationId else { return }

        guard scope.scope == .profileDevice else {
            pendingDeletes.removeValue(forKey: identity)
            saveCache(for: context.cacheKey)
            setSyncError(nil, for: key)
            return
        }

        do {
            let response = try await transport.effectiveValues(
                keys: [key],
                requestIdentity: context.requestIdentity
            )
            guard contextIsCurrent(context),
                  pendingDeletes[identity]?.operationId == pendingDelete.operationId else { return }
            guard let row = response.byKey[key] else {
                setSyncError(Self.missingEffectiveValueMessage, for: key)
                return
            }
            guard applyEffectiveValue(row, for: key) else { return }
            pendingDeletes.removeValue(forKey: identity)
            saveCache(for: context.cacheKey)
        } catch {
            guard contextIsCurrent(context),
                  pendingDeletes[identity]?.operationId == pendingDelete.operationId else { return }
            setSyncError(Self.message(for: error), for: key)
        }
    }

    /// Decode and apply one key atomically. A future value for one setting must
    /// not prevent compatible siblings from reconciling, and its source must
    /// never be paired with a stale value from an earlier successful read.
    @discardableResult
    private func applyEffectiveValue(
        _ row: EffectiveSettingValue,
        for key: SettingKey
    ) -> Bool {
        do {
            switch key {
            case .navPrimaryMenu:
                let menu: PrimaryMenuPreference?
                if row.value.isNull {
                    menu = nil
                } else {
                    let decoded = try row.value.decoded(as: PrimaryMenuPreference.self)
                    guard decoded.isValid else {
                        throw SettingsAPIError.invalidValue(
                            message: "The primary menu value is not valid for this client."
                        )
                    }
                    menu = decoded
                }
                storedPrimaryMenu = menu
                storedPrimaryMenuSource = row.source
            case .navShortcuts:
                let decoded = try row.value.decoded(as: NavigationShortcutsPreference.self)
                storedShortcuts = Self.sanitizedShortcuts(decoded)
            case .uiCardPresentation:
                let presentation = try row.value.decoded(as: CardPresentationPreference.self)
                storedCardPresentation = presentation
                storedCardPresentationSource = row.source
            default:
                throw SettingsAPIError.unknownSetting(key: key.rawValue)
            }
            setSyncError(nil, for: key)
            return true
        } catch {
            setSyncError(Self.effectiveValueDecodeMessage, for: key)
            return false
        }
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
        // Held changes are not sent again on their own (owner decision D4).
        guard enqueueOutbox(context: context, where: { _, retry in !retry.isHeld }) else { return true }
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
        return pendingSyncWrites.values.allSatisfy(\.retry.isHeld)
            && pendingShortcutOperations.values.allSatisfy(\.retry.isHeld)
            && pendingDeletes.values.allSatisfy(\.retry.isHeld)
    }

    /// One outbox entry: a value write by key, a shortcut operation by item
    /// identity, or a delete by `key|scope`.
    private enum OutboxEntry: Hashable {
        case value(String)
        case shortcut(String)
        case delete(String)
    }

    /// Queue every outbox entry `include` accepts, deletes first, then
    /// shortcuts in authored order, then value writes. Returns whether
    /// anything was queued.
    @discardableResult
    private func enqueueOutbox(
        context: OperationContext,
        where include: (OutboxEntry, OutboxRetryState) -> Bool
    ) -> Bool {
        let deletes = pendingDeletes.sorted(by: { $0.key < $1.key })
            .filter { include(.delete($0.key), $0.value.retry) }
        let pendingShortcuts = pendingShortcutOperations
            .filter { include(.shortcut($0.key), $0.value.retry) }
            .values
            .sorted {
                if $0.sequence == $1.sequence { return $0.item.id < $1.item.id }
                return $0.sequence < $1.sequence
            }
        let pending = Self.keys.compactMap { key -> (SettingKey, SettingScopeIdentity, PendingSyncWrite)? in
            guard let write = pendingSyncWrites[key.rawValue], include(.value(key.rawValue), write.retry),
                  let scope = Self.writeScope(for: key) else { return nil }
            return (key, scope, write)
        }
        guard !deletes.isEmpty || !pendingShortcuts.isEmpty || !pending.isEmpty else { return false }

        for (identity, delete) in deletes {
            guard let key = Self.deleteKey(identity),
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
        for (key, scope, write) in pending {
            enqueuePersist(
                key: key,
                scope: scope,
                write: write,
                context: context
            )
        }
        return true
    }

    // MARK: - Held changes

    /// Records one failed send that a retry could fix and returns whether the
    /// change is now held (the retry bound ran out).
    private func recordRetryableFailure(_ state: inout OutboxRetryState) -> Bool {
        state.failedAttempts += 1
        if state.failedAttempts > writeRetryPolicy.maximumAutomaticRetries {
            state.isHeld = true
        }
        return state.isHeld
    }

    /// One timer for every change still retrying, paced by the one that has
    /// failed least. It re-queues only changes that already failed: anything
    /// newer is queued by its own edit.
    private func scheduleOutboxRetry(context: OperationContext) {
        let retrying = pendingSyncWrites.values.map(\.retry)
            + pendingShortcutOperations.values.map(\.retry)
            + pendingDeletes.values.map(\.retry)
        guard let attempt = retrying
            .filter({ !$0.isHeld && $0.failedAttempts > 0 })
            .map(\.failedAttempts)
            .min() else { return }
        outboxRetryTask?.cancel()
        let delay = writeRetryPolicy.delay(forAttempt: attempt)
        outboxRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.contextIsCurrent(context) else { return }
            self.outboxRetryTask = nil
            self.enqueueOutbox(context: context, where: { _, retry in !retry.isHeld && retry.failedAttempts > 0 })
        }
    }

    /// "Try Again": send every held change once more with a fresh retry
    /// budget.
    func retryHeldChanges() {
        guard let context = operationContext() else { return }
        var released = Set<OutboxEntry>()
        for (key, var write) in pendingSyncWrites where write.retry.isHeld {
            write.retry = OutboxRetryState()
            pendingSyncWrites[key] = write
            released.insert(.value(key))
            if let settingKey = SettingKey(rawValue: key) { setSyncError(nil, for: settingKey) }
        }
        for (identity, var operation) in pendingShortcutOperations where operation.retry.isHeld {
            operation.retry = OutboxRetryState()
            pendingShortcutOperations[identity] = operation
            released.insert(.shortcut(identity))
            shortcutSyncErrorsByIdentity.removeValue(forKey: identity)
        }
        for (identity, var delete) in pendingDeletes where delete.retry.isHeld {
            delete.retry = OutboxRetryState()
            pendingDeletes[identity] = delete
            released.insert(.delete(identity))
            if let key = Self.deleteKey(identity) { setSyncError(nil, for: key) }
        }
        saveCache(for: context.cacheKey)
        updateSyncErrorMessage()
        enqueueOutbox(context: context, where: { entry, _ in released.contains(entry) })
    }

    /// "Discard Held Change": forget every held change and repaint what the
    /// server holds. Nothing is sent.
    func discardHeldChanges() async {
        guard let targetCacheKey = cacheKey() else { return }
        for (key, write) in pendingSyncWrites where write.retry.isHeld {
            pendingSyncWrites.removeValue(forKey: key)
            if let settingKey = SettingKey(rawValue: key) { setSyncError(nil, for: settingKey) }
        }
        for (identity, operation) in pendingShortcutOperations where operation.retry.isHeld {
            pendingShortcutOperations.removeValue(forKey: identity)
            shortcutSyncErrorsByIdentity.removeValue(forKey: identity)
            // Undo the optimistic pin or unpin now, so the menu is right even
            // when the refresh below cannot reach the server.
            rollbackRejectedShortcut(operation)
        }
        for (identity, delete) in pendingDeletes where delete.retry.isHeld {
            pendingDeletes.removeValue(forKey: identity)
            if let key = Self.deleteKey(identity) { setSyncError(nil, for: key) }
        }
        reconcilePendingShortcutPlacementError()
        saveCache(for: targetCacheKey)
        updateSyncErrorMessage()
        await refresh()
    }

    /// Keys whose effective value a refresh must not paint over, because a
    /// held change for them is still shown locally.
    private var heldOutboxKeys: Set<SettingKey> {
        var keys = Set<SettingKey>()
        for (key, write) in pendingSyncWrites where write.retry.isHeld {
            if let settingKey = SettingKey(rawValue: key) { keys.insert(settingKey) }
        }
        if pendingShortcutOperations.values.contains(where: \.retry.isHeld) {
            keys.insert(.navShortcuts)
        }
        for (identity, delete) in pendingDeletes where delete.retry.isHeld {
            if let key = Self.deleteKey(identity) { keys.insert(key) }
        }
        return keys
    }

    private func completeSave() {
        pendingSaveCount = max(0, pendingSaveCount - 1)
        isSaving = pendingSaveCount > 0
    }

    private func loadCache(for key: String?) {
        defer { updateHeldState() }
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

    private func updateHeldState() {
        let held = pendingSyncWrites.values.contains(where: \.retry.isHeld)
            || pendingShortcutOperations.values.contains(where: \.retry.isHeld)
            || pendingDeletes.values.contains(where: \.retry.isHeld)
        if hasHeldChanges != held { hasHeldChanges = held }
    }

    private func saveCache(for key: String?) {
        updateHeldState()
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
              !profileId.isEmpty else { return nil }
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

    private static func deleteKey(_ identity: String) -> SettingKey? {
        identity.split(separator: "|", maxSplits: 1).first.flatMap { SettingKey(rawValue: String($0)) }
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
    private static let effectiveValueDecodeMessage =
        "Could not read this interface preference from the server."
    private static let missingEffectiveValueMessage =
        "The server did not return this interface preference."

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
                  !operation.operationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            if case .builtin = operation.item { continue }

            if let existing = migrated[canonicalIdentity] {
                let existingWins = existing.sequence > operation.sequence
                    || (existing.sequence == operation.sequence
                        && existing.operationId >= operation.operationId)
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
        let mapped = SettingsAPIError.from(error)
        switch mapped {
        case .serverUpgradeRequired, .unknownSetting:
            return "Update this Silo server to sync interface preferences."
        default:
            return mapped.writeFailure == .release
                ? "The server didn't accept this change, so it wasn't saved."
                : "Saved on this device. Sync will resume when the server is reachable."
        }
    }

    private static func shortcutMessage(for error: Error) -> String {
        switch SettingsAPIError.from(error) {
        case .invalidValue(let message) where message.contains("256"):
            return "This profile already has 256 navigation shortcuts. Unpin one and try again."
        case .invalidValue:
            return "The server rejected this shortcut. Check the selection and try again."
        default:
            return Self.message(for: error)
        }
    }

    /// The server proved the shortcut operation can never land as authored.
    /// A key the server does not know means it needs an update, which is not
    /// a verdict on this operation.
    private static func isDefinitiveShortcutRejection(_ error: Error) -> Bool {
        let mapped = SettingsAPIError.from(error)
        if case .unknownSetting = mapped { return false }
        return mapped.writeFailure == .release
    }
}
