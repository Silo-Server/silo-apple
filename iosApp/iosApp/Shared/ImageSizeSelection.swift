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
    /// Artwork slot → the query parameter that takes its width in device
    /// pixels (`"poster"` → `"poster_width"`). Absent on servers that only
    /// take one size per response.
    var slotWidthParams: [String: String]? = nil
}

/// The width, in points, one screen draws each artwork slot at. Slots are
/// named for the response field: `backdrop` governs `backdrop_url` even when
/// an episode's backdrop holds its still.
struct ArtworkSlotWidths: Equatable, Sendable {
    /// Whole-response size for the slots given no width here.
    var imageSize: String?
    var poster: CGFloat?
    var backdrop: CGFloat?
    var logo: CGFloat?
    var still: CGFloat?
    var photo: CGFloat?

    /// Each width keyed by the capability's slot name.
    var pointWidths: [String: CGFloat] {
        ["poster": poster, "backdrop": backdrop, "logo": logo, "still": still, "photo": photo]
            .compactMapValues { $0 }
    }
}

enum ImageSizeSelection {
    static let requestedSize = "large"
    /// The widest slot width the server accepts.
    static let maxSlotWidth = 7680

    /// One size for every artwork URL in the response: `large` when the
    /// server offers it. Top Shelf, and tvOS reads on servers without
    /// per-slot widths.
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

    /// Entries asking for each slot at the width `slots` draws it on a
    /// display of `displayScale`. A server without per-slot widths gets the
    /// one-size entries above instead.
    static func queryEntries(
        capability: ImageSizeCapabilityResponse?,
        slots: ArtworkSlotWidths,
        displayScale: CGFloat,
        prefersLargeImages: Bool
    ) -> [String: String] {
        guard let capability, capability.state == "available" else { return [:] }
        guard let params = capability.slotWidthParams, !params.isEmpty else {
            return queryEntries(capability: capability, prefersLargeImages: prefersLargeImages)
        }
        var entries: [String: String] = [:]
        if let size = slots.imageSize, !capability.param.isEmpty, capability.sizes.contains(size) {
            entries[capability.param] = size
        }
        for (slot, points) in slots.pointWidths {
            guard let name = params[slot], !name.isEmpty,
                  let pixels = pixelWidth(points: points, displayScale: displayScale) else { continue }
            entries[name] = String(pixels)
        }
        return entries
    }

    /// `points` at `displayScale`, rounded up and capped at what the server
    /// accepts. Nil for a width that is not positive.
    static func pixelWidth(points: CGFloat, displayScale: CGFloat) -> Int? {
        let pixels = (points * max(displayScale, 1)).rounded(.up)
        guard pixels.isFinite, pixels >= 1 else { return nil }
        return min(Int(pixels), maxSlotWidth)
    }
}
