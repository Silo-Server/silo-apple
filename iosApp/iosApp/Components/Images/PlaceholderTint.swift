import SwiftUI

/// The muted gradient behind art-less tiles. A seed always gets the same
/// colour, on every device and launch, so a tile does not change colour
/// between visits.
enum PlaceholderTint {
    /// FNV-1a, because `Hasher` is randomly seeded per process.
    static func hue(for seed: String) -> Double {
        let hash = seed.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return Double(hash % 360) / 360.0
    }

    /// Dark enough at both stops for white text to clear WCAG AA.
    static func gradient(for seed: String) -> Gradient {
        let hue = hue(for: seed)
        return Gradient(colors: [
            Color(hue: hue, saturation: 0.50, brightness: 0.42),
            Color(hue: hue, saturation: 0.32, brightness: 0.22),
        ])
    }
}
