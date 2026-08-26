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
    let textlessPoster: TextlessPosterCapability?

    init(
        schemaVersion: Int,
        param: String,
        sizes: [String],
        widths: [String: [String: Int]],
        originalMaxWidthPx: Int,
        textlessPoster: TextlessPosterCapability? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.param = param
        self.sizes = sizes
        self.widths = widths
        self.originalMaxWidthPx = originalMaxWidthPx
        self.textlessPoster = textlessPoster
    }
}

struct TextlessPosterCapability: Codable, Equatable {
    let endpoint: String
    let supportedTypes: [String]
}

struct TextlessPosterResponse: Codable, Equatable {
    let posterUrl: String?
}

enum ImageSizeSelection {
    static let requestedSize = "large"

    static func queryEntries(
        capability: ImageSizeCapabilityResponse?,
        prefersLargeImages: Bool
    ) -> [String: String] {
        guard prefersLargeImages,
              let capability,
              capability.schemaVersion == 1,
              !capability.param.isEmpty,
              capability.sizes.contains(requestedSize)
        else { return [:] }
        return [capability.param: requestedSize]
    }
}
