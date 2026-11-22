import Foundation

/// Display labels for the shared extras/videos kind vocabulary.
///
/// Ported from the web client's `web/src/lib/extraKinds.ts` so all three
/// clients name a kind identically. Keep in sync with the server's kind
/// list; unknown kinds degrade to the generic label rather than showing a
/// raw identifier like `behind_the_scenes` to a viewer.
enum ExtraKindLabels {
    private static let singular: [String: LocalizedStringResource] = [
        "trailer": .catalogExtraTrailer,
        "teaser": .catalogExtraTeaser,
        "featurette": .catalogExtraFeaturette,
        "clip": .catalogExtraClip,
        "behind_the_scenes": .catalogExtraBehindTheScenes,
        "bloopers": .catalogExtraBloopers,
        "deleted_scene": .catalogExtraDeletedScene,
        "other": .catalogExtraOtherExtra,
    ]

    /// Singular label for one card (`extraKindLabel` on web).
    static func label(for kind: String) -> String {
        AppLanguage.string(singular[kind] ?? .catalogExtraOtherExtra)
    }

}
