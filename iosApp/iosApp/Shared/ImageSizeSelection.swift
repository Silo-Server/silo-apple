import Foundation

/// Shared wire contract for `GET /api/v2/images/capabilities`. The main app and
/// Top Shelf extension both decode this lightweight model so every tvOS
/// artwork surface negotiates the same server-advertised query parameter.
struct ImageSizeCapabilityResponse: Codable, Equatable {
    let param: String
    let sizes: [String]
    let widths: [String: [String: Int]]
    let originalMaxWidthPx: Int
    let state: String
    var storageBackend: String? = nil
    var delivery: String? = nil
}

enum ImageSizeSelection {
    static let requestedSize = "large"

    static func queryEntries(
        capability: ImageSizeCapabilityResponse?,
        prefersLargeImages: Bool
    ) -> [String: String] {
        guard prefersLargeImages,
              let capability,
              capability.state == "available",
              !capability.param.isEmpty,
              capability.sizes.contains(requestedSize)
        else { return [:] }
        return [capability.param: requestedSize]
    }
}
