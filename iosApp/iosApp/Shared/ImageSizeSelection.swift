import Foundation

/// Shared wire contract for `GET /api/v1/images/capability`. The main app and
/// Top Shelf extension both decode this lightweight model so every tvOS
/// artwork surface negotiates the same server-advertised query parameter.
struct ImageSizeCapabilityResponse: Codable, Equatable {
    let schemaVersion: Int
    let param: String
    let sizes: [String]
    let widths: [String: [String: Int]]
    let originalMaxWidthPx: Int
}

enum ImageSizeSelection {
    /// Production's public artwork delivery currently returns 404 for a
    /// subset of the advertised large poster/still objects, while the same
    /// items' medium objects are healthy. Keep tvOS on the server-negotiated
    /// w500 tier until capability can express per-rung readiness.
    static let requestedSize = "medium"

    static func queryEntries(
        capability: ImageSizeCapabilityResponse?,
        requestsNegotiatedSize: Bool
    ) -> [String: String] {
        guard requestsNegotiatedSize,
              let capability,
              capability.schemaVersion == 1,
              !capability.param.isEmpty,
              capability.sizes.contains(requestedSize)
        else { return [:] }
        return [capability.param: requestedSize]
    }
}
