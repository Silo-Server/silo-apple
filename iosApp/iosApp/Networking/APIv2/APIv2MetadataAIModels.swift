import Foundation

// MARK: getMetadataAICapability

/// `GET /api/v2/capabilities/metadata-ai`.
/// `on_view` is an open string on the wire; unknown values decode to `.off`.
struct APIv2MetadataAICapability: Decodable {
    let state: String
    let revision: String
    let allowed: Bool
    let onView: MetadataAIStatus.OnViewMode

    var playerValue: MetadataAIStatus {
        let enabled = allowed && state == "available"
        return MetadataAIStatus(enabled: enabled, onView: enabled ? onView : .off)
    }
}

// MARK: translateCatalogItemDescription

/// Body for `POST /api/v2/catalog/items/{id}/translate-description`.
struct APIv2TranslateDescriptionBody: Encodable {
    let targetLanguage: String
}

/// The 202 job. A recently failed job may come back without new work.
struct APIv2MetadataTranslationJob: Decodable {
    let id: String
    let targetKind: String
    let contentId: String
    let targetLanguage: String
    let status: String
    var failed: Bool { status == "failed" || status == "canceled" || status == "cancelled" }
}
