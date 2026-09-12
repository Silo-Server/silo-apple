import Foundation

// Wire-only response and read-provenance types that `APIv2Client` returns and
// that have no v1 counterpart on this branch. Each is a plain value; the
// consumers that project them into screens arrive with the gate 3 surfaces.

// MARK: Metadata AI

/// `GET /api/v2/capabilities/metadata-ai`.
struct APIv2MetadataAICapability: Decodable {
    let state: String
    let revision: String
    let onView: MetadataAIStatus.OnViewMode

    var playerValue: MetadataAIStatus {
        MetadataAIStatus(enabled: state == "available", onView: state == "available" ? onView : .off)
    }
}

extension MetadataAIStatus {
    init(enabled: Bool, onView: OnViewMode) {
        self.enabled = enabled
        self.onView = onView
    }
}

/// `POST /api/v2/catalog/items/{id}/translate-description` (202).
struct APIv2MetadataTranslationJob: Decodable {
    let id: String
    let targetKind: String
    let contentId: String
    let targetLanguage: String
    let status: String
    var failed: Bool { status == "failed" || status == "canceled" || status == "cancelled" }
}

// MARK: Onboarding

/// One displayed onboarding flow: the owner that read it, the state's entity
/// tag, and the flow. A progress write is accepted only for this session.
struct APIv2OnboardingSession: Sendable {
    let id: UUID
    let auth: CapturedOrdinaryRequestAuth
    let tag: String
    let state: OnboardingState
    let flow: OnboardingFlow?
}

// MARK: Collections

/// The validator belongs to the canonical read and its captured viewer, never
/// a list row. `auth` is the full owner the read was fenced on; a later
/// mutation is fenced on the same owner.
struct CollectionEditVersion: Sendable {
    let path: String
    let etag: String
    let identity: HTTPRequestIdentity
    let account: RefreshAccountIdentity
    let auth: CapturedOrdinaryRequestAuth
}

struct CollectionEditor<Value> {
    let value: Value
    let version: CollectionEditVersion
}

// MARK: Requests

/// `GET /api/v2/requests/mine` page.
struct APIv2RequestsPage: Decodable {
    let items: [MediaRequest]
    let page: APIv2Page
}

// MARK: Home

/// In-memory provenance for the Home section consumers, mirroring
/// `APIv2LibrarySectionsRead`. The owner never enters a cache document.
struct APIv2HomeSectionsRead {
    let auth: CapturedOrdinaryRequestAuth
    let response: SectionsResponse
    var sections: [ResolvedSection] { response.sections }
}

// MARK: Notifications and push (iOS)

#if os(iOS)
/// `GET /api/v2/notifications/sync` page.
struct APIv2NotificationSyncPage: Decodable, Equatable {
    static let defaultLimit = 50

    let items: [APIv2NotificationSyncItem]
    let page: APIv2Page
    let syncCursor: String
    let unreadCount: Int
    let initialSnapshot: Bool
}

struct APIv2NotificationSyncItem: Decodable, Equatable, Identifiable {
    let id: String
    let type: String?
    let profileId: String
    let createdAt: Date?
    let readAt: Date?
}

/// `POST /api/v2/devices/push/apple` response.
struct APIv2ApplePushRegistration: Decodable {
    let generation: String
    let removed: Bool
    let id: String
    let serverDeviceId: String
    let enabled: Bool
    let pushMode: String
    /// Long-lived, profile-scoped token for the Notification Service
    /// extension's display fetch. Absent on older servers.
    let displayToken: String?
    /// RFC 3339 expiry of `displayToken`. Absent with it.
    let displayTokenExpiresAt: String?
}
#endif
