import Foundation

/// DiceBear avatar presets. Port of `web/src/lib/profile-avatars.ts` — the
/// web app is the source of truth for the avatar contract, and by mirroring
/// the same style list, word lists, and batch formula we get stable, shared
/// seeds across clients (the same `batch` index + style yields the same 18
/// avatars on web and iOS).
///
/// Wire format sent to `POST /api/v2/profiles`:
///
///     preset:dicebear:<styleId>:<seed>
///
/// Renderers decode this back through `ProfileAvatarResolver.imageURL(for:)`
/// which synthesises the DiceBear PNG URL.

enum ProfileAvatarPresets {
    /// Available DiceBear styles, in display order. Kept in sync with
    /// `PROFILE_AVATAR_STYLES` on the web.
    static let styles: [Style] = [
        Style(id: "identicon", label: "Identicon",
              summary: "Geometric patterns"),
        Style(id: "initials", label: "Initials",
              summary: "Letter-based with bold backgrounds"),
        Style(id: "bottts-neutral", label: "Bottts",
              summary: "Modular robot faces"),
        Style(id: "fun-emoji", label: "Fun Emoji",
              summary: "Big, colorful faces"),
        Style(id: "pixel-art-neutral", label: "Pixel Art",
              summary: "Retro pixel characters"),
    ]

    static let defaultStyleId: String = "fun-emoji"

    static let optionCount: Int = 18

    /// Build one batch of 18 presets for the given style. The `(batch, index)`
    /// pair maps deterministically into the word lists using the same
    /// multipliers the web client uses — clients compare notes by batch.
    static func batch(styleId: String, batch: Int = 0) -> [Preset] {
        let style = styles.contains(where: { $0.id == styleId })
            ? styleId
            : defaultStyleId
        let styleLen = style.count

        return (0..<optionCount).map { index in
            let adjectiveIndex = ((batch * 7) + (index * 3) + styleLen)
                .modulo(adjectives.count)
            let nounIndex = ((batch * 11) + (index * 5) + (styleLen * 2))
                .modulo(nouns.count)
            let seed = "\(adjectives[adjectiveIndex])-\(nouns[nounIndex])"
            return Preset(styleId: style, seed: seed)
        }
    }

    /// Serialise a preset for the `avatar` field on the create/update
    /// profile request.
    static func presetRef(styleId: String, seed: String) -> String {
        "preset:dicebear:\(styleId):\(seed)"
    }

    /// DiceBear PNG URL for a preset at the requested pixel size. PNG keeps
    /// the renderer simple (SwiftUI `AsyncImage` can't decode SVG without
    /// extra plumbing); the web uses SVG because browsers can.
    static func imageURL(styleId: String, seed: String, size: Int = 256) -> String {
        let s = styleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? styleId
        let d = seed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? seed
        return "https://api.dicebear.com/9.x/\(s)/png?seed=\(d)&size=\(size)"
    }

    struct Style: Identifiable, Hashable {
        let id: String
        let label: String
        let summary: String
    }

    struct Preset: Hashable, Identifiable {
        let styleId: String
        let seed: String
        var id: String { "\(styleId):\(seed)" }
        var ref: String { presetRef(styleId: styleId, seed: seed) }
        var previewURL: String { imageURL(styleId: styleId, seed: seed) }
    }

    // MARK: - Seed word lists

    private static let adjectives: [String] = [
        "cosmic", "jelly", "starlight", "mango", "bubble", "neon", "marble",
        "comet", "snappy", "pepper", "glimmer", "ripple", "pocket", "candy",
        "ember", "mochi", "sprout", "twinkle", "whiz", "plasma", "mint",
        "velvet", "crunchy", "sunbeam", "toffee", "splash", "boomer", "lunar",
        "fizzy", "biscuit", "rocket", "cobalt",
    ]

    private static let nouns: [String] = [
        "otter", "rocket", "fox", "cookie", "gecko", "bunny", "penguin",
        "puffin", "tiger", "panda", "saturn", "wizard", "skater", "nebula",
        "robot", "pirate", "meteor", "sprite", "pebble", "nova", "dragon",
        "donut", "parrot", "panther", "goblin", "muffin", "laser", "pickle",
        "falcon", "sunset", "toaster", "bandit",
    ]
}

private extension Int {
    /// Positive-modulo; Swift's `%` returns a negative remainder for negative
    /// operands, which isn't what the web batch formula expects.
    func modulo(_ m: Int) -> Int {
        let r = self % m
        return r >= 0 ? r : r + m
    }
}
