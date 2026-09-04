import Foundation

/// Display labels for the shared extras/videos kind vocabulary.
///
/// Ported from the web client's `web/src/lib/extraKinds.ts` so all three
/// clients name a kind identically. Keep in sync with the server's kind
/// list; unknown kinds degrade to the generic label rather than showing a
/// raw identifier like `behind_the_scenes` to a viewer.
enum ExtraKindLabels {
    private static let singular: [String: String] = [
        "trailer": "Trailer",
        "teaser": "Teaser",
        "featurette": "Featurette",
        "clip": "Clip",
        "behind_the_scenes": "Behind the Scenes",
        "bloopers": "Bloopers",
        "deleted_scene": "Deleted Scene",
        "other": "Extra",
    ]

    /// Singular label for one card (`extraKindLabel` on web).
    static func label(for kind: String) -> String {
        singular[kind] ?? "Extra"
    }

}
